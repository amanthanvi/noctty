//! Session persistence, restore, placement and scrollback snapshots.
const win32 = @import("../win32.zig");
const runtime = win32.session_runtime;
const killThreadTimer = runtime.killThreadTimer;
const Allocator = runtime.Allocator;
const App = runtime.App;
const CoreApp = runtime.CoreApp;
const Host = runtime.Host;
const LPCWSTR = runtime.LPCWSTR;
const MONITORINFO = runtime.MONITORINFO;
const RECT = runtime.RECT;
const ShellProjectionSteps = runtime.ShellProjectionSteps;
const SplitTreeSurface = runtime.SplitTreeSurface;
const Surface = runtime.Surface;
const SurfaceInitOptions = runtime.SurfaceInitOptions;
const Tab = runtime.Tab;
const TestSession = win32.test_support.TestSession;
const UINT_PTR = runtime.UINT_PTR;
const WINDOWPLACEMENT = runtime.WINDOWPLACEMENT;
const WindowStart = runtime.WindowStart;
const WindowStartTestApp = win32.test_support.WindowStartTestApp;
const WorkAreas = runtime.WorkAreas;
const appendOwnedString = runtime.appendOwnedString;
const applyDefaultProfileConfig = runtime.applyDefaultProfileConfig;
const applyProfileSurfaceConfig = runtime.applyProfileSurfaceConfig;
const apprt = runtime.apprt;
const builtin = runtime.builtin;
const c = runtime.c;
const cli_args = runtime.cli_args;
const configpkg = runtime.configpkg;
const createTestHostWindow = win32.test_support.createTestHostWindow;
const defaultProfileForKey = runtime.defaultProfileForKey;
const default_title = runtime.default_title;
const gl_startup = runtime.gl_startup;
const internal_os = runtime.internal_os;
const lastError = runtime.lastError;
const listProfilesForConfig = runtime.listProfilesForConfig;
const log = runtime.log;
const makeParentDirAbsolute = runtime.makeParentDirAbsolute;
const markRecoveryAttemptAtPath = runtime.markRecoveryAttemptAtPath;
const placementTestApp = win32.test_support.placementTestApp;
const placementTestSurface = win32.test_support.placementTestSurface;
const profileIndexByKey = runtime.profileIndexByKey;
const recovery_set_aside_suffix = runtime.recovery_set_aside_suffix;
const rectEqual = runtime.rectEqual;
const restore_grab = runtime.restore_grab;
const restoredRectOnScreen = runtime.restoredRectOnScreen;
const restoresMaximized = runtime.restoresMaximized;
const runOnHiddenDesktop = win32.test_support.runOnHiddenDesktop;
const setAsideCrashedSessionState = runtime.setAsideCrashedSessionState;
const setMinimizedNormalRect = runtime.setMinimizedNormalRect;
const shouldInheritSplitWorkingDirectory = runtime.shouldInheritSplitWorkingDirectory;
const shouldResetNewTabWorkingDirectory = runtime.shouldResetNewTabWorkingDirectory;
const startsWithIgnoreCase = runtime.startsWithIgnoreCase;
const startupNamesProfile = runtime.startupNamesProfile;
const std = runtime.std;
const sys = runtime.sys;
const terminal = runtime.terminal;
const terminal_options = runtime.terminal_options;
const testUserProfileList = runtime.testUserProfileList;
const testVisualStudioList = runtime.testVisualStudioList;
const unixMillis = runtime.unixMillis;
const win32_session_persistence = runtime.win32_session_persistence;
const win32_session_state = runtime.win32_session_state;
const win32_shell = runtime.win32_shell;
const windows = runtime.windows;
const windows_shell = runtime.windows_shell;
const workspaceRectToScreen = runtime.workspaceRectToScreen;
const writePersistentFileAlloc = runtime.writePersistentFileAlloc;

/// Suffix for a saved session that was restored and then ended by itself
/// before it was used (`App.setAsideFailedRestore`). Its own slots: these
/// copies must never take the ones the crash-loop breaker needs.
pub const restore_ended_suffix = ".restore-ended";

/// Move the saved session at `path` aside, as a restore that ended by itself
/// before it was used: renamed into a free `.restore-ended` slot, never
/// deleted or replaced. With every slot taken it stays where it is, and the
/// next launch restores it again: a session the user can see beats one this
/// would have to delete or overwrite a copy to move. Returns whether it moved.
pub fn setAsideSessionStateAt(alloc: Allocator, path: []const u8) bool {
    const destination = win32_session_persistence.quarantineFileAlloc(
        alloc,
        path,
        restore_ended_suffix,
        .keep_source,
    ) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            error.QuarantineFull => log.warn("win32 session: the restored session ended by itself before any input; left in place, every {s} name is taken", .{restore_ended_suffix}),
            else => log.warn("win32 session: the restored session ended by itself before any input; not moved aside err={}", .{err}),
        }
        return false;
    };
    defer alloc.free(destination);
    log.warn("win32 session: the restored session ended by itself before any input; moved it to {s}", .{destination});
    return true;
}

test "win32 a restore that ended by itself is moved aside, never deleted or replaced" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "session-state.json" });
    defer std.testing.allocator.free(path);

    // Every restore that ends this way is kept, each in a slot of its own.
    var name_buf: [64]u8 = undefined;
    for (0..win32_session_persistence.max_quarantined_copies) |index| {
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "{{\"schema_version\":1,\"windows\":[],\"n\":{d}}}", .{index});
        try tmp.dir.writeFile(.{ .sub_path = "session-state.json", .data = content });
        try std.testing.expect(setAsideSessionStateAt(std.testing.allocator, path));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access("session-state.json", .{}));
        const name = if (index == 0)
            "session-state.json" ++ restore_ended_suffix
        else
            try std.fmt.bufPrint(&name_buf, "session-state.json{s}.{d}", .{ restore_ended_suffix, index });
        const moved = try tmp.dir.readFileAlloc(std.testing.allocator, name, 64);
        defer std.testing.allocator.free(moved);
        try std.testing.expectEqualStrings(content, moved);
    }
    // Nothing left to move.
    try std.testing.expect(!setAsideSessionStateAt(std.testing.allocator, path));

    // Every slot taken: the session stays, and no copy is replaced.
    const latest = "{\"schema_version\":1,\"windows\":[],\"n\":5}";
    try tmp.dir.writeFile(.{ .sub_path = "session-state.json", .data = latest });
    try std.testing.expect(!setAsideSessionStateAt(std.testing.allocator, path));
    const stayed = try tmp.dir.readFileAlloc(std.testing.allocator, "session-state.json", 64);
    defer std.testing.allocator.free(stayed);
    try std.testing.expectEqualStrings(latest, stayed);
    const first = try tmp.dir.readFileAlloc(std.testing.allocator, "session-state.json" ++ restore_ended_suffix, 64);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"schema_version\":1,\"windows\":[],\"n\":0}", first);

    // These copies never take the crash-loop breaker's slots: with all of
    // them taken, a session the last launches died restoring still moves.
    try std.testing.expect(setAsideCrashedSessionState(std.testing.allocator, path));
    const crashed = try tmp.dir.readFileAlloc(std.testing.allocator, "session-state.json" ++ recovery_set_aside_suffix, 64);
    defer std.testing.allocator.free(crashed);
    try std.testing.expectEqualStrings(latest, crashed);
}

pub fn sessionStatePolicyAllows(safe_mode: bool, policy: configpkg.Config.WindowSaveState) bool {
    return !safe_mode and policy != .never;
}

pub const SessionRestoreTransaction = struct {
    app: ?*App = null,
    host: ?*Host = null,
    core_first: *bool,
    core_first_before: bool,
    committed: bool = false,

    pub fn init(app: *App) SessionRestoreTransaction {
        return .{
            .core_first = &app.core_app.first,
            .core_first_before = app.core_app.first,
        };
    }

    pub fn noteSurface(self: *SessionRestoreTransaction, surface: *Surface) void {
        if (self.host == null) {
            self.app = surface.app;
            self.host = surface.host;
        }
    }

    pub fn commit(self: *SessionRestoreTransaction) void {
        self.committed = true;
    }

    pub fn rollback(self: *SessionRestoreTransaction) void {
        if (self.committed) return;
        if (self.app) |app| if (self.host) |host| {
            app.rollbackSessionRestoreHost(host);
            // A failed DestroyWindow deliberately retains the partial host.
            // Do not make that live surface look like a fresh first surface.
            if (std.mem.indexOfScalar(*Host, app.registry.hosts.items, host) != null) return;
        };
        self.core_first.* = self.core_first_before;
    }
};

pub fn sessionRestorePolicyAllows(
    safe_mode: bool,
    policy: configpkg.Config.WindowSaveState,
    initial_window: bool,
    has_initial_command: bool,
    startup_profile_picker: bool,
    /// A directory or a profile named on the command line.
    explicit_startup: bool,
) bool {
    return sessionStatePolicyAllows(safe_mode, policy) and
        initial_window and
        !has_initial_command and
        !startup_profile_picker and
        !explicit_startup;
}

pub const SessionSaveKind = enum { final, checkpoint };

/// How long the session must stay unchanged before a structural change is
/// saved (`App.scheduleSessionCheckpoint`).
pub const session_checkpoint_delay_ms: u32 = 1000;

/// Held for the life of the one process that owns `session-state.json`.
/// An exclusive byte-range lock on the `.lock` sibling, so the kernel drops
/// it when the owner exits or crashes and the next launch can take over.
pub const SessionOwnerLock = struct {
    file: std.fs.File,

    /// Null when another live process holds it.
    pub fn acquire(alloc: Allocator, state_path: []const u8) !?SessionOwnerLock {
        try makeParentDirAbsolute(state_path);
        const lock_path = try std.fmt.allocPrint(alloc, "{s}.lock", .{state_path});
        defer alloc.free(lock_path);
        const file = std.fs.createFileAbsolute(lock_path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        return .{ .file = file };
    }

    pub fn release(self: SessionOwnerLock) void {
        self.file.close();
    }
};

/// Resolve `%LOCALAPPDATA%\noctty\session-state.json`. Caller
/// frees with `core_app.alloc`.
pub fn sessionStatePath(self: *const App) ?[]u8 {
    return self.localAppDataPath("session-state.json");
}

pub fn sessionStateEnabled(self: *const App) bool {
    // Only the owner, the process that was eligible to restore the saved
    // session and then got its first window, may replace it or move it
    // aside. The restore policy is re-checked so a config reload
    // (window-save-state = never) still stops it.
    return self.session_owner != null and self.sessionRestoreEligible();
}

/// Take the saved session for this process, on the restore-eligible
/// startup path only. One live process owns it (decision D10): with
/// `single-instance = false`, or when forwarding failed, a second
/// instance starts with a fresh window instead of restoring the same
/// workspace a second time, and never saves over it.
pub fn acquireSessionOwnerLock(self: *App) ?SessionOwnerLock {
    if (self.session_state_excluded_for_elevation) return null;
    const path = self.sessionStatePath() orelse return null;
    defer self.core_app.alloc.free(path);
    return SessionOwnerLock.acquire(self.core_app.alloc, path) catch |err| {
        log.warn("win32 session: ownership lock unavailable; not restoring or saving err={}", .{err});
        return null;
    } orelse {
        log.info("win32 session: another instance owns the saved session; starting without it", .{});
        return null;
    };
}

/// Ownership is for a session this process may replace. One it left alone
/// stays free, so the build that wrote it can still restore it.
pub fn adoptSessionOwner(self: *App, lock: ?SessionOwnerLock) void {
    if (self.session_state_left_alone) {
        if (lock) |held| held.release();
        return;
    }
    self.session_owner = lock;
}

pub fn releaseSessionOwnership(self: *App) void {
    if (self.session_owner) |lock| lock.release();
    self.session_owner = null;
}

/// Crash insurance on a display-topology change, the moment a GPU
/// driver is most likely to fault (#299). Every host receives the same
/// message, so one save per second is plenty.
pub fn checkpointSessionState(self: *App) void {
    const now = sys.GetTickCount64();
    if (self.session_checkpoint_ms) |last| if (now -% last < 1000) return;
    self.session_checkpoint_ms = now;
    _ = self.saveSessionState(.checkpoint);
}

/// The shell model's `persist_session`: a window, tab or pane opened,
/// closed or moved. Saved as crash insurance (Windows Terminal saves its
/// layout automatically for the same reason) once the change settles,
/// so a burst such as a layout launch or repeated undo writes once, and
/// the last step of the burst is the one on disk. Re-arming the thread
/// timer restarts its interval. Nothing is armed for a process that
/// does not own the saved session, including one still restoring it.
pub fn scheduleSessionCheckpoint(self: *App) void {
    if (!self.sessionStateEnabled()) return;
    const timer_id = sys.SetTimer(null, self.session_checkpoint_timer_id orelse 0, session_checkpoint_delay_ms, null);
    if (timer_id == 0) {
        log.warn("failed to start session checkpoint timer err={}", .{windows.kernel32.GetLastError()});
        return;
    }
    self.session_checkpoint_timer_id = timer_id;
}

pub fn stopSessionCheckpointTimer(self: *App) void {
    killThreadTimer(&self.session_checkpoint_timer_id);
}

pub fn onSessionCheckpointTimer(self: *App) void {
    self.stopSessionCheckpointTimer();
    self.session_checkpoint_ms = sys.GetTickCount64();
    _ = self.saveSessionState(.checkpoint);
}

pub fn sessionRestoreEligible(self: *const App) bool {
    if (self.embedding_mode) return false;
    return sessionRestorePolicyAllows(
        self.safe_mode,
        self.config.@"window-save-state",
        self.config.@"initial-window",
        self.config.@"initial-command" != null,
        self.startup_profile_picker,
        self.explicit_startup_working_directory or startupNamesProfile(&self.config),
    );
}

pub fn loadSessionState(self: *App) !?std.json.Parsed(win32_session_state.SessionState) {
    if (self.session_state_excluded_for_elevation) return null;
    if (!self.sessionRestoreEligible()) return null;
    const path = self.sessionStatePath() orelse return null;
    defer self.core_app.alloc.free(path);
    return self.loadSessionStateAt(path);
}

pub fn loadSessionStateAt(self: *App, path: []const u8) !?std.json.Parsed(win32_session_state.SessionState) {
    return switch (win32_session_persistence.loadAlloc(
        self.core_app.alloc,
        path,
        win32_session_persistence.default_max_state_bytes,
    )) {
        .missing => null,
        .oversized => oversized: {
            log.warn("win32 session restore: state exceeds size limit; leaving file untouched and not saving over it", .{});
            self.session_state_left_alone = true;
            break :oversized null;
        },
        .transient => |err| {
            // Unreadable now is not unwanted: a scanner may hold a newer
            // build's file for a moment, and the next checkpoint would
            // replace what this run never saw.
            self.session_state_left_alone = true;
            return err;
        },
        .newer_schema => newer: {
            log.warn("win32 session restore: state was written by a newer noctty; leaving file untouched and not saving over it", .{});
            self.session_state_left_alone = true;
            break :newer null;
        },
        .corrupt => |err| corrupt: {
            self.quarantineInvalidSessionState(path, err);
            break :corrupt null;
        },
        .loaded => |parsed| parsed,
    };
}

pub fn restoreSessionState(self: *App) !bool {
    var parsed = self.loadSessionState() catch |err| {
        log.warn("win32 session restore: state read failed; leaving file untouched err={}", .{err});
        return false;
    } orelse return false;
    defer parsed.deinit();

    const ledger_path = self.recoveryLedgerPath();
    defer if (ledger_path) |value| self.core_app.alloc.free(value);
    if (ledger_path) |value| {
        markRecoveryAttemptAtPath(self.core_app.alloc, value, &self.recovery_startup, .{ .session_restore = unixMillis() });
    }
    defer if (ledger_path) |value| {
        markRecoveryAttemptAtPath(self.core_app.alloc, value, &self.recovery_startup, .session_restored);
    };
    // Debug-only fault for the restore crash-loop harness: the process
    // ends mid-restore, as a release abort does (ExitProcess(3)), without
    // the breakpoint a Debug panic raises.
    if (builtin.mode == .Debug and std.process.hasEnvVarConstant("NOCTTY_DEBUG_CRASH_SESSION_RESTORE")) {
        std.process.exit(3);
    }

    var restored = false;
    for (parsed.value.windows) |window| {
        if (self.restoreSessionWindow(window)) |surface| {
            restored = true;
            self.activateSurface(surface);
        } else |err| {
            log.warn("win32 session restore: skipped window err={}", .{err});
            // Handled: the dialog and the recovery ledger describe only
            // the failure that ends the launch.
            gl_startup.clearOpenGLStartupFailure();
        }
    }
    // From here on, input that reaches a running program, or a terminal
    // opening, uses the session.
    self.restored_session_untouched = restored;

    return restored;
}

pub fn quarantineInvalidSessionState(self: *App, path: []const u8, parse_error: anyerror) void {
    const destination = win32_session_persistence.quarantineCorruptFileAlloc(
        self.core_app.alloc,
        path,
    ) catch |err| {
        log.warn("win32 session restore: quarantine failed path={s} parse_err={} move_err={}", .{ path, parse_error, err });
        return;
    };
    defer self.core_app.alloc.free(destination);
    log.warn("win32 session restore: quarantined unreadable state path={s} parse_err={}", .{ destination, parse_error });
}

pub fn restoreSessionWindow(
    self: *App,
    window: win32_session_state.Window,
) !*Surface {
    var transaction = SessionRestoreTransaction.init(self);
    defer transaction.rollback();
    var host: ?*Host = null;
    var window_surface: ?*Surface = null;

    for (window.tabs, 0..) |saved_tab, tab_index| {
        const tab_surface = try self.restoreSessionTab(
            saved_tab,
            host,
            tab_index,
            &transaction,
        );
        if (host == null) {
            host = tab_surface.host;
            if (host) |created_host| {
                applyRestoredWindowPlacement(created_host, window) catch |err| {
                    log.warn("win32 session restore: window placement failed err={}", .{err});
                };
            }
        }
        if (window_surface == null or tab_index == window.selected_tab) {
            window_surface = tab_surface;
        }
    }

    const restored_host = host orelse return error.EmptyTabs;
    if (restored_host.tabs.items.len == 0) return error.EmptyTabs;
    restored_host.active_tab = @min(window.selected_tab, restored_host.tabs.items.len - 1);
    const active_tab = &restored_host.tabs.items[restored_host.active_tab];
    const selected = active_tab.focusedSurface() orelse window_surface orelse return error.EmptyTabs;
    // `maximize` and `fullscreen` apply to a restored window too (#496),
    // and a launched layout, which has no saved state, takes them as any
    // new window does. The window has its saved rect by now (as the rect
    // it returns to, if a minimized launch minimized it), so that is the
    // normal rect it returns to.
    var start = WindowStart.fromConfig(&self.config);
    if (window.state == .fullscreen) {
        start.fullscreen = true;
        start.maximize = start.maximize or (window.fullscreen_maximized orelse false);
    }
    selected.applyWindowStart(start);
    // Fullscreen is kept per surface, and every tab shares the window's.
    if (start.fullscreen and selected.fullscreen) syncRestoredHostWindowState(restored_host, selected);
    transaction.commit();
    return selected;
}

/// Every pane already shares this HWND. Only copy its cached state;
/// generic window cloning allocates and repeats native placement calls.
pub fn syncRestoredHostWindowState(host: *Host, source: *const Surface) void {
    for (host.tabs.items) |*tab| {
        for (tab.tree.nodes) |node| switch (node) {
            .leaf => |surface| if (surface != source) surface.copySharedWindowStateFrom(source, .{}),
            .split => {},
        };
    }
}

pub fn restoreSessionTab(
    self: *App,
    saved_tab: win32_session_state.Tab,
    existing_host: ?*Host,
    tab_index: usize,
    transaction: *SessionRestoreTransaction,
) !*Surface {
    const layout = saved_tab.layout;
    if (layout.root >= layout.nodes.len) return error.EmptyLayout;
    const node_surfaces = try self.core_app.alloc.alloc(?*Surface, layout.nodes.len);
    defer self.core_app.alloc.free(node_surfaces);
    @memset(node_surfaces, null);

    // The panes are made in the saved tree's shape: each split's second
    // half is split off the pane standing for its first half, before that
    // pane is split further, so later splits nest inside the first half.
    // The shell model and the native tree then have the saved topology,
    // and closing a restored pane focuses the pane beside it on screen.
    // The native tree takes the saved ratios below.
    const Pending = struct { node: usize, leaf: *Surface };
    const pending = try self.core_app.alloc.alloc(Pending, layout.nodes.len);
    defer self.core_app.alloc.free(pending);
    const first_index = firstSessionLayoutPane(layout, layout.root) orelse return error.EmptyLayout;
    const first = try self.restoreSessionPane(
        layout.nodes[first_index].pane,
        existing_host,
        null,
        tab_index,
        .right,
        transaction,
    );
    pending[0] = .{ .node = layout.root, .leaf = first };
    var pending_len: usize = 1;
    while (pending_len > 0) {
        pending_len -= 1;
        const item = pending[pending_len];
        switch (layout.nodes[item.node]) {
            .pane => node_surfaces[item.node] = item.leaf,
            .split => |split| {
                const second_index = firstSessionLayoutPane(layout, split.second) orelse return error.EmptyLayout;
                const second = try self.restoreSessionPane(
                    layout.nodes[second_index].pane,
                    existing_host,
                    item.leaf,
                    tab_index,
                    switch (split.axis) {
                        .horizontal => .right,
                        .vertical => .down,
                    },
                    transaction,
                );
                if (pending_len + 2 > pending.len) return error.InvalidTreeShape;
                pending[pending_len] = .{ .node = split.second, .leaf = second };
                pending[pending_len + 1] = .{ .node = split.first, .leaf = item.leaf };
                pending_len += 2;
            },
        }
    }

    // `selected_leaf` counts panes in the saved node order.
    var selected = first;
    var leaf_index: usize = 0;
    for (layout.nodes, node_surfaces) |node, surface| switch (node) {
        .pane => {
            if (leaf_index == saved_tab.selected_leaf) selected = surface orelse first;
            leaf_index += 1;
        },
        .split => {},
    };
    if (self.registry.findTabForSurface(selected)) |found| {
        // No errdefer: nothing can fail before the tab takes the tree, and
        // from then on the tab frees it, also when `layout` fails.
        const restored_tree = try buildRestoredSessionSplitTree(
            self.core_app.alloc,
            saved_tab.layout,
            node_surfaces,
        );
        found.tab.tree.deinit();
        found.tab.tree = restored_tree;
        if (found.tab.findHandle(selected)) |handle| found.tab.focused = handle;
        // The model made each new pane its tab's focus; the saved
        // selection is this tab's.
        self.commitShellSurfaceActivation(selected);
        try found.host.layout();
    }
    return selected;
}

test "restoreSessionTab leaves the restored tree to the tab when layout fails" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var host: Host = undefined;
    var left: Surface = undefined;
    var right: Surface = undefined;
    var session: TestSession = .{};
    try session.init(.{
        .core_app = &core_app,
        .app = &app,
        .hosts = &.{.{ .storage = &host, .register = true }},
        .surfaces = &.{
            .{ .storage = &left, .host = &host },
            .{ .storage = &right, .host = &host },
        },
    });
    defer session.deinit();
    const host_hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(host_hwnd);
    host.hwnd = host_hwnd;

    // The saved ratio tells the restored tree from the one the panes
    // were created with.
    const nodes = [_]win32_session_state.Node{
        .{ .split = .{ .axis = .horizontal, .ratio = 0.25, .first = 1, .second = 2 } },
        .{ .pane = .{} },
        .{ .pane = .{} },
    };
    const layout: win32_session_state.LayoutTree = .{ .root = 0, .nodes = &nodes };
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var dry_run = try buildRestoredSessionSplitTree(counting.allocator(), layout, &.{ null, &left, &right });
    dry_run.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    core_app.alloc = failing.allocator();
    defer core_app.alloc = std.testing.allocator;

    const Hook = struct {
        var panes: [2]*Surface = undefined;
        var created: usize = 0;
        var failing_ref: *std.testing.FailingAllocator = undefined;
        var build_allocations: usize = 0;

        fn createSurface(
            hook_app: *App,
            _: *const configpkg.Config,
            _: LPCWSTR,
            opts: SurfaceInitOptions,
        ) anyerror!*Surface {
            const alloc = hook_app.core_app.alloc;
            const surface = panes[created];
            created += 1;
            const target = hook_app.registry.findHostById(opts.host_id.?).?;
            const source = opts.clone_state_from orelse {
                var tab = try Tab.init(alloc, target.nextTabId(), surface);
                errdefer tab.deinit();
                try target.tabs.append(alloc, tab);
                return surface;
            };
            const found = hook_app.registry.findTabForSurface(@constCast(source)).?;
            var inserted = try SplitTreeSurface.init(alloc, surface);
            defer inserted.deinit();
            const next = try found.tab.tree.split(alloc, found.tab.focused, opts.split_direction, 0.5, &inserted);
            found.tab.tree.deinit();
            found.tab.tree = next;
            // The last pane is in. Fail the first allocation after the
            // restored tree is built: the one `layout` makes once the
            // tab has taken that tree.
            failing_ref.fail_index = failing_ref.alloc_index + build_allocations;
            return surface;
        }
    };
    Hook.panes = .{ &left, &right };
    Hook.created = 0;
    Hook.failing_ref = &failing;
    Hook.build_allocations = counting.alloc_index;
    app.test_create_window_surface = &Hook.createSurface;

    var transaction = SessionRestoreTransaction.init(&app);
    // Before the fix the restore's own errdefer freed the restored tree
    // while the tab kept it, and the session teardown freed it again.
    try std.testing.expectError(error.OutOfMemory, app.restoreSessionTab(
        .{ .selected_leaf = 1, .layout = layout },
        &host,
        0,
        &transaction,
    ));
    try std.testing.expectEqual(@as(usize, 1), host.tabs.items.len);
    const tab = &host.tabs.items[0];
    try std.testing.expectEqual(@as(f16, 0.25), tab.tree.nodes[0].split.ratio);
    try std.testing.expectEqual(@as(usize, 2), tab.leafCount());
    try std.testing.expectEqual(&right, tab.focusedSurface().?);
}

pub fn restoreSessionPane(
    self: *App,
    pane: win32_session_state.Pane,
    existing_host: ?*Host,
    tab_surface: ?*Surface,
    tab_index: usize,
    split_direction: SplitTreeSurface.Split.Direction,
    transaction: *SessionRestoreTransaction,
) !*Surface {
    const host = existing_host orelse if (tab_surface) |source| source.host else null;
    const open_kind: apprt.surface.NewSurfaceContext = if (host == null)
        .window
    else if (tab_surface == null)
        .tab
    else
        .split;
    var config = try apprt.surface.newConfig(self.core_app, &self.config, open_kind);
    defer config.deinit();

    // `initial-command` (from `-e` or the config option) applies to the
    // ordinary first window. A restored pane's command comes from its
    // saved profile, so clear it: otherwise `Surface.init` prefers it
    // while `app.first` is set and the first pane of a restored session
    // or a launched layout runs the wrong command.
    config.@"initial-command" = null;

    // A refused profile (today: SSH) must not leave its key on the surface
    // either, or a later split of the restored pane would re-resolve it and
    // launch the connection this restore just declined.
    const profile_applied = if (pane.profile) |key|
        try self.applyRestoredProfileConfig(&config, host, key)
    else
        false;
    const default_profile = if (profile_applied) null else try self.applyRestoredDefaultLaunch(&config);
    if (pane.cwd) |cwd| {
        const alloc = config._arena.?.allocator();
        config.@"working-directory" = .{ .path = try alloc.dupe(u8, cwd) };
    }

    const tab_id = if (tab_surface) |source|
        (self.registry.findTabForSurface(source) orelse return error.NoActiveSurface).tab.id
    else
        null;
    const surface = try self.createWindowSurface(&config, default_title, .{
        .host_id = if (host) |existing| existing.id else null,
        .tab_id = tab_id,
        .tab_insert_index = if (host != null and tab_surface == null) tab_index else null,
        .clone_state_from = tab_surface,
        .split_direction = split_direction,
        // `restoreSessionWindow` applies them once the window is placed.
        .config_window_start = false,
    });
    transaction.noteSurface(surface);

    if (profile_applied) {
        try appendOwnedString(self.core_app.alloc, &surface.launch_profile_key, pane.profile.?);
    } else if (default_profile) |profile| try self.noteProfileLaunch(surface, profile);
    if (pane.title_override) |title| try surface.setTitleOverride(title);
    if (pane.tab_title_override) |title| try surface.setTabTitleOverride(title);
    if (pane.cwd) |cwd| try surface.setPwd(cwd);
    const scrollback_lines: usize = self.config.@"window-save-state-scrollback";
    if (scrollback_lines > 0) {
        if (pane.scrollback) |snapshot| {
            _ = surface.restoreSessionScrollback(
                snapshot,
                scrollback_lines,
            ) catch |err| {
                log.warn("win32 session restore: pane snapshot omitted or partial err={}", .{err});
                return surface;
            };
        }
    }
    return surface;
}

pub fn applyRestoredProfileConfig(
    self: *App,
    config: *configpkg.Config,
    host: ?*Host,
    key: []const u8,
) !bool {
    // SSH stays refused below; any other pane of `default-profile`
    // restores without a list.
    if (!startsWithIgnoreCase(key, "ssh:")) {
        if (defaultProfileForKey(&self.config, key)) |profile| {
            if (!isSessionRestorableProfile(profile)) return false;
            try applyProfileSurfaceConfig(config, profile);
            return true;
        }
    }
    if (host) |existing| {
        const profile = (try existing.profileForKey(key)) orelse return false;
        if (!isSessionRestorableProfile(profile)) return false;
        try applyProfileSurfaceConfig(config, profile);
        return true;
    }

    const profiles = try listProfilesForConfig(self.core_app.alloc, &self.config, windows_shell.listProfiles);
    defer windows_shell.deinitProfiles(self.core_app.alloc, profiles);
    return try applyProfileConfigByKey(config, profiles, key);
}

pub fn applyRestoredWindowPlacement(
    host: *Host,
    window: win32_session_state.Window,
) !void {
    const hwnd = host.hwnd orelse return;
    if (try sessionStateWindowRect(window)) |saved| {
        // The saved rect is where the window was, not where there is room
        // for it now: its monitor may be gone.
        const works = WorkAreas.collect();
        const dpi_before = sys.GetDpiForWindow(hwnd);
        var target = restoredRectOnScreen(saved, works.slice(), restore_grab);
        if (sys.IsIconic(hwnd) != 0) {
            // A launch that asked for a minimized window (`start /min`,
            // a shortcut set to Run: Minimized) has Windows minimize the
            // first window's first show. SetWindowPos on a minimized
            // window moves its icon, and it would come back from the
            // taskbar where it was created: give it the rect to return to.
            try setMinimizedNormalRect(hwnd, target);
        } else {
            // The rect is in the pixels of the monitor it was saved on, and is
            // where the window goes: a crossing from the monitor the host was
            // created on must not swap in the DPI suggestion's rescaled size.
            host.restore_placing = true;
            defer host.restore_placing = false;
            for (0..3) |attempt| {
                if (sys.SetWindowPos(
                    hwnd,
                    null,
                    target.left,
                    target.top,
                    target.right - target.left,
                    target.bottom - target.top,
                    c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                ) == 0) return lastError();
                // Windows caps what it is given (a left edge to 16 bits, a
                // width to the largest window), so whether the title bar can
                // be reached is judged on the rect the window ended up with.
                var actual: RECT = undefined;
                if (sys.GetWindowRect(hwnd, &actual) == 0) return lastError();
                const moved = restoredRectOnScreen(actual, works.slice(), restore_grab);
                if (!rectEqual(moved, actual)) {
                    if (attempt == 2) {
                        log.warn("win32 session restore: window stayed off every monitor", .{});
                        break;
                    }
                    target = moved;
                    continue;
                }
                // The layout that follows a DPI change can resize it once
                // more: apply the same rect again once.
                if (sys.GetDpiForWindow(hwnd) == dpi_before or rectEqual(actual, target)) break;
            }
        }
    }
    if ((window.state orelse .normal) == .maximized) {
        _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
    }
}

/// Whether a window holds tabs the session records (`hostSessionTabs`).
/// The quick terminal and a window kept empty for undo hold none.
pub fn hasSessionWindows(self: *const App) bool {
    for (self.registry.hosts.items) |host| {
        if (hostSessionTabs(host).len > 0) return true;
    }
    return false;
}

/// Whether `host` is the session's last window: it holds session tabs
/// and no other window does.
pub fn closingEndsSession(self: *const App, host: *const Host) bool {
    if (hostSessionTabs(host).len == 0) return false;
    for (self.registry.hosts.items) |other| {
        if (other != host and hostSessionTabs(other).len > 0) return false;
    }
    return true;
}

/// Save the session as it ends, while its windows are whole: teardown
/// frees their panes' strings before `windowDestroyed`. The saved
/// session is what was open, however it ended, unless that was only a
/// restore that failed (`setAsideFailedRestore`). A caller whose close
/// rolls back clears the flag again.
pub fn saveSessionAsItEnds(self: *App) void {
    self.session_state_saved_before_last_host_close = true;
    if (self.sessionIsFailedRestore()) return self.setAsideFailedRestore();
    if (builtin.is_test) self.test_session_saves_as_it_ends += 1;
    _ = self.saveSessionState(.final);
}

/// Whether the session is a restore that failed: the startup restore
/// brought it back, nothing has used it since, and every program it
/// shows has ended by itself. Saving it back would restore the same dead
/// panes at every launch.
pub fn sessionIsFailedRestore(self: *const App) bool {
    if (!self.restored_session_untouched) return false;
    var panes: usize = 0;
    for (self.registry.hosts.items) |host| for (hostSessionTabs(host)) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| : (panes += 1) {
            if (!entry.view.programEnded()) return false;
        }
    };
    return panes > 0;
}

/// The session ends as a restore that failed. Saving it back would open
/// and close it again at every launch, so the saved session is moved
/// aside instead (`setAsideSessionStateAt`) and the next launch starts
/// fresh. A rename, never a delete or a replace. Not at a sign-out,
/// which ends the programs itself.
pub fn setAsideFailedRestore(self: *App) void {
    if (self.session_ending) return;
    if (builtin.is_test) self.test_failed_restores_set_aside += 1;
    if (self.session_state_excluded_for_elevation or !self.sessionStateEnabled()) return;
    const path = self.sessionStatePath() orelse return;
    defer self.core_app.alloc.free(path);
    _ = setAsideSessionStateAt(self.core_app.alloc, path);
}

/// `.final` is the owner's save as the session ends; a `.checkpoint`
/// leaves alone the snapshot `saveSessionAsItEnds` already took.
pub fn saveSessionState(self: *const App, kind: SessionSaveKind) bool {
    if (self.session_state_excluded_for_elevation) return false;
    if (!self.sessionStateEnabled()) return false;
    // A sign-out's snapshot is final; see `session_ending`.
    if (self.session_ending) return false;
    if (kind == .checkpoint and self.session_state_saved_before_last_host_close) return false;
    const path = self.sessionStatePath() orelse return false;
    defer self.core_app.alloc.free(path);
    return self.writeSessionStateAt(path);
}

/// Write the session's windows to `path`. With none to write, writes
/// nothing and leaves the file as it is: every way the last window goes
/// saves it first, so an empty snapshot says only that nothing is open,
/// not what to restore, and a delete could not be taken back. Nor does
/// it write a restore that failed (`sessionIsFailedRestore`): the file
/// holds that session already, or held it until `setAsideFailedRestore`
/// moved it, and writing it again (a checkpoint after an undo) would
/// bring it back for the next launch, or fill another set-aside slot.
pub fn writeSessionStateAt(self: *const App, path: []const u8) bool {
    if (self.sessionIsFailedRestore()) return false;
    const scrollback_lines: usize = self.config.@"window-save-state-scrollback";
    for ([_]usize{ scrollback_lines, 0 }, 0..) |attempt_lines, attempt_index| {
        if (attempt_index == 1) {
            if (scrollback_lines == 0) break;
            log.warn("win32 session save: retrying without scrollback", .{});
        }

        var arena = std.heap.ArenaAllocator.init(self.core_app.alloc);
        defer arena.deinit();

        const state = self.buildSessionState(arena.allocator(), attempt_lines) catch |err| {
            log.warn("win32 session save: snapshot failed scrollback_lines={d} err={}", .{ attempt_lines, err });
            continue;
        };
        if (state.windows.len == 0) return false;

        const encoded = win32_session_state.encodeAlloc(self.core_app.alloc, state) catch |err| {
            log.warn("win32 session save: encode failed scrollback_lines={d} err={}", .{ attempt_lines, err });
            continue;
        };
        defer self.core_app.alloc.free(encoded);
        const max_bytes = if (attempt_lines > 0)
            win32_session_persistence.default_max_state_bytes
        else
            win32_session_persistence.max_layout_state_bytes;
        if (encoded.len > max_bytes) {
            log.warn("win32 session save: state exceeds write limit bytes={d}", .{encoded.len});
            continue;
        }
        writePersistentFileAlloc(self.core_app.alloc, path, encoded) catch |err| {
            log.warn("win32 session save: write failed path={s} err={}", .{ path, err });
            return false;
        };
        return true;
    }
    return false;
}

pub fn buildSessionState(
    self: *const App,
    alloc: Allocator,
    scrollback_lines: usize,
) !win32_session_state.SessionState {
    var count: usize = 0;
    for (self.registry.hosts.items) |host| {
        if (hostSessionTabs(host).len > 0) count += 1;
    }

    const windows_state = try alloc.alloc(win32_session_state.Window, count);
    var remaining_scrollback_budget = win32_session_state.max_total_scrollback_bytes;
    var built: usize = 0;
    for (self.registry.hosts.items) |host| {
        if (hostSessionTabs(host).len == 0) continue;
        windows_state[built] = try buildSessionWindow(
            alloc,
            host,
            .session,
            scrollback_lines,
            &remaining_scrollback_budget,
        );
        built += 1;
    }

    return .{ .windows = windows_state };
}

/// What a window snapshot is for. `.session` is this process's own restore
/// state; `.layout` is a user-visible named layout file, which carries only
/// the shape fields and no window geometry.
pub const SnapshotScope = enum { session, layout };

pub fn buildSessionWindow(
    alloc: Allocator,
    host: *Host,
    scope: SnapshotScope,
    scrollback_lines: usize,
    remaining_scrollback_budget: *usize,
) !win32_session_state.Window {
    const session_tabs = hostSessionTabs(host);
    if (scope == .layout and session_tabs.len == 0) return error.EmptyTabs;
    const tabs = try alloc.alloc(win32_session_state.Tab, session_tabs.len);
    var selected_tab: usize = 0;
    for (session_tabs, 0..) |*tab, i| {
        if (i <= host.active_tab) selected_tab = i;
        tabs[i] = try buildSessionTab(
            alloc,
            tab,
            scope,
            scrollback_lines,
            remaining_scrollback_budget,
        );
    }

    var window: win32_session_state.Window = .{
        .selected_tab = selected_tab,
        .tabs = tabs,
    };
    // Geometry is restore state, not layout shape.
    if (scope == .layout) return window;
    if (sessionWindowPlacement(host)) |placed| {
        if (placed.rect) |rect| {
            window.x = rect.left;
            window.y = rect.top;
            window.width = rect.right - rect.left;
            window.height = rect.bottom - rect.top;
        }
        window.state = if (placed.fullscreen) .fullscreen else if (placed.maximized) .maximized else .normal;
        window.fullscreen_maximized = if (placed.fullscreen) placed.maximized else null;
    }
    return window;
}

pub fn buildSessionTab(
    alloc: Allocator,
    tab: *const Tab,
    scope: SnapshotScope,
    scrollback_lines: usize,
    remaining_scrollback_budget: *usize,
) !win32_session_state.Tab {
    var selected_leaf: usize = 0;
    var leaf_index: usize = 0;
    for (tab.tree.nodes, 0..) |node, node_index| {
        switch (node) {
            .leaf => {},
            .split => continue,
        }
        if (tab.focused.idx() == node_index) selected_leaf = leaf_index;
        leaf_index += 1;
    }

    return .{
        .selected_leaf = selected_leaf,
        .layout = try buildSessionLayout(
            alloc,
            tab,
            scope,
            scrollback_lines,
            remaining_scrollback_budget,
        ),
    };
}

pub fn buildSessionLayout(
    alloc: Allocator,
    tab: *const Tab,
    scope: SnapshotScope,
    scrollback_lines: usize,
    remaining_scrollback_budget: *usize,
) !win32_session_state.LayoutTree {
    if (tab.tree.nodes.len > std.math.maxInt(u16)) return error.TooManySessionLayoutNodes;
    const nodes = try alloc.alloc(win32_session_state.Node, tab.tree.nodes.len);
    for (tab.tree.nodes, 0..) |node, i| {
        nodes[i] = switch (node) {
            // The two pane literals are deliberately separate. Anything
            // added to the session pane below (terminal contents, process
            // state) must stay out of user-visible layout files unless it
            // is also added to the layout literal on purpose. Neither
            // snapshot may persist an SSH launch for unattended restore.
            .leaf => |surface| switch (scope) {
                .session => .{ .pane = .{
                    .cwd = sessionSnapshotPaneText(
                        "cwd",
                        if (surface.launched_ssh) null else surface.pwd,
                    ),
                    .profile = sessionSnapshotPaneText(
                        "profile",
                        if (surface.launched_ssh) null else surface.launch_profile_key,
                    ),
                    .title_override = sessionSnapshotPaneText(
                        "title_override",
                        surface.title_override,
                    ),
                    .tab_title_override = sessionSnapshotPaneText(
                        "tab_title_override",
                        if (surface.launched_ssh) null else surface.tab_title_override,
                    ),
                    .scrollback = surface.captureSessionScrollback(
                        alloc,
                        scrollback_lines,
                        remaining_scrollback_budget,
                    ) catch |err| snapshot: {
                        log.warn("win32 session save: pane snapshot omitted err={}", .{err});
                        break :snapshot null;
                    },
                } },
                .layout => .{ .pane = .{
                    .cwd = sessionSnapshotPaneText(
                        "cwd",
                        if (surface.launched_ssh) null else surface.pwd,
                    ),
                    .profile = sessionSnapshotPaneText(
                        "profile",
                        if (surface.launched_ssh) null else surface.launch_profile_key,
                    ),
                    .title_override = sessionSnapshotPaneText(
                        "title_override",
                        surface.title_override,
                    ),
                    .tab_title_override = sessionSnapshotPaneText(
                        "tab_title_override",
                        if (surface.launched_ssh) null else surface.tab_title_override,
                    ),
                } },
            },
            .split => |split| .{ .split = .{
                .axis = switch (split.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @floatCast(split.ratio),
                .first = @intFromEnum(split.left),
                .second = @intFromEnum(split.right),
            } },
        };
    }
    return .{ .root = 0, .nodes = nodes };
}

/// Drop a single pane field that a hostile source (OSC 7 pwd, OSC 0/2
/// title) made unsafe, rather than failing the whole save. The load path
/// stays strict: `win32_session_state.validatePane` rejects the file.
pub fn sessionSnapshotPaneText(field: []const u8, value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    // A working directory on a network share or device is never written:
    // spawn would replace it with the home folder anyway, and a file that
    // names one invites the next reader to touch it. This also drops one
    // restored from a session saved before such pwds were refused.
    if (std.mem.eql(u8, field, "cwd") and internal_os.path.isNetworkOrDevicePath(text)) {
        log.warn("win32 session save: dropping network or device cwd", .{});
        return null;
    }
    if (win32_session_state.isValidPaneText(text)) return text;
    log.warn("win32 session save: dropping unsafe pane field field={s} len={}", .{ field, text.len });
    return null;
}

/// The tabs of `host` a session or layout file records: none for the
/// quick terminal, which is never restored.
pub fn hostSessionTabs(host: *const Host) []const Tab {
    return if (host.quick_terminal) &.{} else host.tabs.items;
}

/// The node index of the first pane under `index`, following each
/// split's first half. Null for an index or chain the layout does not
/// hold, which validation rejects before a restore.
pub fn firstSessionLayoutPane(layout: win32_session_state.LayoutTree, index: usize) ?usize {
    var current = index;
    var steps: usize = 0;
    while (current < layout.nodes.len and steps < layout.nodes.len) : (steps += 1) {
        switch (layout.nodes[current]) {
            .pane => return current,
            .split => |split| current = split.first,
        }
    }
    return null;
}

pub fn buildRestoredSessionSplitTree(
    alloc: Allocator,
    layout: win32_session_state.LayoutTree,
    node_surfaces: []const ?*Surface,
) (Allocator.Error || error{ InvalidTreeShape, TooManySessionLayoutNodes })!SplitTreeSurface {
    if (layout.nodes.len == 0 or layout.nodes.len != node_surfaces.len) {
        return error.InvalidTreeShape;
    }
    if (layout.root >= layout.nodes.len) return error.InvalidTreeShape;
    if (layout.nodes.len > std.math.maxInt(SplitTreeSurface.Node.Handle.Backing)) {
        return error.TooManySessionLayoutNodes;
    }

    const invalid_index = std.math.maxInt(usize);
    const remap = try alloc.alloc(usize, layout.nodes.len);
    defer alloc.free(remap);
    @memset(remap, invalid_index);

    if (layout.root == 0) {
        for (remap, 0..) |*slot, i| slot.* = i;
    } else {
        const stack = try alloc.alloc(usize, layout.nodes.len);
        defer alloc.free(stack);

        remap[layout.root] = 0;
        stack[0] = layout.root;
        var stack_len: usize = 1;
        var next_index: usize = 1;
        while (stack_len > 0) {
            stack_len -= 1;
            const saved_index = stack[stack_len];
            switch (layout.nodes[saved_index]) {
                .pane => {},
                .split => |split| {
                    const children = [_]u16{ split.first, split.second };
                    for (children) |child| {
                        const child_index: usize = child;
                        if (child_index >= layout.nodes.len) return error.InvalidTreeShape;
                        if (remap[child_index] == invalid_index) {
                            remap[child_index] = next_index;
                            next_index += 1;
                            stack[stack_len] = child_index;
                            stack_len += 1;
                        }
                    }
                },
            }
        }
        if (next_index != layout.nodes.len) return error.InvalidTreeShape;
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const tree_nodes = try arena.allocator().alloc(SplitTreeSurface.Node, layout.nodes.len);

    for (layout.nodes, 0..) |node, saved_index| {
        const restored_index = remap[saved_index];
        if (restored_index == invalid_index) return error.InvalidTreeShape;
        tree_nodes[restored_index] = switch (node) {
            .pane => .{ .leaf = node_surfaces[saved_index] orelse return error.InvalidTreeShape },
            .split => |split| .{ .split = .{
                .layout = switch (split.axis) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @floatCast(split.ratio),
                .left = @enumFromInt(remap[split.first]),
                .right = @enumFromInt(remap[split.second]),
            } },
        };
    }

    return .{
        .arena = arena,
        .nodes = tree_nodes,
        .zoomed = null,
    };
}

pub fn sessionStateWindowRect(window: win32_session_state.Window) !?RECT {
    const x = window.x orelse {
        if (window.y == null and window.width == null and window.height == null) return null;
        return error.InvalidWindowRect;
    };
    const y = window.y orelse return error.InvalidWindowRect;
    const width = window.width orelse return error.InvalidWindowRect;
    const height = window.height orelse return error.InvalidWindowRect;
    if (width <= 0 or height <= 0) return error.InvalidWindowRect;
    const right = std.math.add(i32, x, width) catch return error.InvalidWindowRect;
    const bottom = std.math.add(i32, y, height) catch return error.InvalidWindowRect;
    return .{
        .left = x,
        .top = y,
        .right = right,
        .bottom = bottom,
    };
}

pub const SessionWindowPlacement = struct {
    /// The window's normal rect in screen coordinates.
    rect: ?RECT,
    /// It is, or restores to, maximized.
    maximized: bool,
    fullscreen: bool = false,
};

pub fn sessionWindowPlacement(host: *Host) ?SessionWindowPlacement {
    return sessionWindowPlacementOn(host, null);
}

/// `monitor` stands in for the window's monitor, so a test can give it
/// the taskbar this machine lacks.
pub fn sessionWindowPlacementOn(host: *Host, monitor: ?MONITORINFO) ?SessionWindowPlacement {
    const hwnd = host.hwnd orelse return null;
    // Keep fullscreen separately from the return placement. The popup's
    // current rect covers its monitor and is not its normal rect.
    if (host.activeSurface()) |surface| if (surface.fullscreen) {
        return sessionFullscreenWindowPlacement(surface, surface.fullscreenReturn(hwnd), monitor);
    };
    var maximized = sys.IsZoomed(hwnd) != 0;
    var rect: RECT = undefined;
    if (maximized or sys.IsIconic(hwnd) != 0) {
        var placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
        placement.length = @sizeOf(WINDOWPLACEMENT);
        if (sys.GetWindowPlacement(hwnd, &placement) != 0) {
            maximized = restoresMaximized(hwnd, &placement);
            // Workspace coordinates, offset from the screen's by a taskbar
            // on the top or left. Every other state saves screen
            // coordinates, and restore applies them as such.
            rect = placement.rcNormalPosition;
            if (monitor) |info| {
                rect = workspaceRectToScreen(rect, info);
            } else if (sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST)) |nearest| {
                var info: MONITORINFO = std.mem.zeroes(MONITORINFO);
                info.cbSize = @sizeOf(MONITORINFO);
                if (sys.GetMonitorInfoW(nearest, &info) != 0) rect = workspaceRectToScreen(rect, info);
            }
        } else if (sys.GetWindowRect(hwnd, &rect) == 0) {
            return .{ .rect = null, .maximized = maximized };
        }
    } else if (sys.GetWindowRect(hwnd, &rect) == 0) {
        return .{ .rect = null, .maximized = maximized };
    }

    if (rect.right <= rect.left or rect.bottom <= rect.top) return .{ .rect = null, .maximized = maximized };
    return .{ .rect = rect, .maximized = maximized };
}

/// A failed current-monitor lookup still has the enter-time placement.
/// Never substitute the fullscreen popup's bounds for its normal rect.
pub fn sessionFullscreenWindowPlacement(
    surface: *const Surface,
    result: anyerror!Surface.FullscreenReturn,
    monitor: ?MONITORINFO,
) ?SessionWindowPlacement {
    const back = result catch |err| fallback: {
        log.warn("win32 session save: fullscreen window placement failed; using captured placement err={}", .{err});
        break :fallback Surface.FullscreenReturn{
            .rect = surface.restore_rect,
            .placement = surface.restore_placement,
            .monitor = if (surface.restore_monitor) |source| source.info else null,
        };
    };
    const maximized = back.placement.showCmd == c.SW_MAXIMIZE;
    var rect = back.rect;
    if (maximized) {
        rect = back.placement.rcNormalPosition;
        if (monitor orelse back.monitor) |info| rect = workspaceRectToScreen(rect, info);
    }
    if (rect.right <= rect.left or rect.bottom <= rect.top) return null;
    return .{ .rect = rect, .maximized = maximized, .fullscreen = true };
}

/// `applyDefaultProfileLaunch` for a restored pane whose own profile did
/// not apply, except that restore never connects over SSH by itself: with
/// an SSH `default-profile` the pane gets the automatic shell, in place
/// of the SSH command `Config` made the default.
pub fn applyRestoredDefaultLaunch(self: *const App, config: *configpkg.Config) !?*const windows_shell.Profile {
    if (self.defaultProfileApplies(config) and config._default_profile.?.kind == .ssh) {
        config.command = null;
        try config.resolveWindowsDefaultCommand();
        return null;
    }
    return try self.applyDefaultProfileLaunch(config);
}

pub fn rollbackSessionRestoreHost(self: *App, host: *Host) void {
    const previous_quitting = self.quitting;
    self.quitting = true;
    defer self.quitting = previous_quitting;
    self.session_restore_rollback_host = host;
    defer self.session_restore_rollback_host = null;
    host.clearStructuralHistory(.normal);
    if (host.hwnd) |hwnd| {
        if (sys.DestroyWindow(hwnd) == 0) {
            const destroy_err = windows.kernel32.GetLastError();
            if (sys.IsWindow(hwnd) != 0) {
                log.err("failed to destroy partially restored host; retaining ownership err={}", .{
                    destroy_err,
                });
                return;
            }
        }
    }
    if (self.shell_runtime_initialized) {
        if (host.shell_id) |window_id| self.shell_runtime.rollbackWindow(window_id);
    }
    self.removeHost(host);
}

pub fn sessionScrollbackLineAllowed(line: []const u8) bool {
    const view = std.unicode.Utf8View.init(line) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |codepoint| {
        if (codepoint == '\t') continue;
        if (codepoint < 0x20 or
            codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint <= 0x9f)) return false;
    }
    return true;
}

pub fn captureTerminalScrollbackSnapshotAlloc(
    alloc: Allocator,
    scratch_alloc: Allocator,
    terminal_state: *terminal.Terminal,
    max_lines_requested: usize,
    remaining_budget: *usize,
    captured_at_unix_ms: u64,
) !?win32_session_state.ScrollbackSnapshot {
    const requested_lines = @min(max_lines_requested, win32_session_state.max_scrollback_lines);
    if (requested_lines == 0 or remaining_budget.* == 0) return null;

    const all = terminal_state.screens.active.selectAll() orelse return null;
    var end = all.end();
    end.x = end.node.data.size.cols - 1;

    const plain_capacity = remaining_budget.* -| win32_session_state.scrollback_snapshot_storage_overhead;
    if (plain_capacity == 0) {
        remaining_budget.* = 0;
        return null;
    }
    const row_bytes = @as(usize, @intCast(terminal_state.cols)) + 1;
    const capacity_lines = @max(plain_capacity / row_bytes, 1);
    var max_lines = @min(requested_lines, capacity_lines);

    const plain_buf = try scratch_alloc.alloc(u8, plain_capacity);
    defer scratch_alloc.free(plain_buf);
    var plain_len: usize = 0;
    var formatter_retries: usize = 0;
    while (true) {
        var start = end.up(max_lines - 1) orelse
            terminal_state.screens.active.pages.getTopLeft(.screen);
        start.x = 0;

        var plain_writer: std.Io.Writer = .fixed(plain_buf);
        var formatter = terminal.formatter.TerminalFormatter.init(terminal_state, .plain);
        formatter.extra = .none;
        formatter.content = .{ .selection = .init(start, end, false) };
        formatter.format(&plain_writer) catch {
            if (max_lines == 1 or formatter_retries == 4) return null;
            max_lines = @max(max_lines / 2, 1);
            formatter_retries += 1;
            continue;
        };
        plain_len = plain_writer.end;
        break;
    }
    const plain = plain_buf[0..plain_len];
    if (plain.len == 0) return null;

    var snapshot_bytes = win32_session_state.scrollback_snapshot_storage_overhead;
    var accepted_count: usize = 0;
    var accepted_start = plain.len;
    var remaining_plain = plain;
    while (true) {
        const separator = std.mem.lastIndexOfScalar(u8, remaining_plain, '\n');
        const line_start = if (separator) |index| index + 1 else 0;
        const line = remaining_plain[line_start..];
        if (line.len > win32_session_state.max_scrollback_line_bytes or
            !sessionScrollbackLineAllowed(line))
        {
            // Invalid lines are omitted without discarding newer safe lines.
        } else {
            const line_bytes = win32_session_state.scrollbackLineStorageBytes(line) orelse break;
            if (line_bytes > remaining_budget.* -| snapshot_bytes) break;
            snapshot_bytes += line_bytes;
            accepted_count += 1;
            accepted_start = line_start;
        }
        const separator_index = separator orelse break;
        remaining_plain = remaining_plain[0..separator_index];
    }
    if (accepted_count == 0) return null;

    const lines = try alloc.alloc([]const u8, accepted_count);
    var built: usize = 0;
    errdefer {
        for (lines[0..built]) |line| alloc.free(line);
        alloc.free(lines);
    }
    var split = std.mem.splitScalar(u8, plain[accepted_start..], '\n');
    while (split.next()) |line| {
        if (built == accepted_count) break;
        if (line.len > win32_session_state.max_scrollback_line_bytes or
            !sessionScrollbackLineAllowed(line)) continue;
        lines[built] = try alloc.dupe(u8, line);
        built += 1;
    }

    remaining_budget.* -= snapshot_bytes;
    return .{
        .captured_at_unix_ms = captured_at_unix_ms,
        .lines = lines,
    };
}

pub fn printSessionSnapshotLine(terminal_state: *terminal.Terminal, line: []const u8) !void {
    var remaining = line;
    while (std.mem.indexOfScalar(u8, remaining, '\t')) |tab_index| {
        try terminal_state.printString(remaining[0..tab_index]);
        terminal_state.horizontalTab();
        remaining = remaining[tab_index + 1 ..];
    }
    try terminal_state.printString(remaining);
    terminal_state.carriageReturn();
    try terminal_state.linefeed();
}

pub fn formatSessionSnapshotMarker(
    buf: []u8,
    captured_at_unix_ms: u64,
) std.fmt.BufPrintError![]const u8 {
    const max_iso8601_unix_ms: u64 = 253_402_300_799_999;
    if (captured_at_unix_ms > max_iso8601_unix_ms) {
        return std.fmt.bufPrint(
            buf,
            "--- SNAPSHOT END | Unix ms {d} ---",
            .{captured_at_unix_ms},
        );
    }

    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = captured_at_unix_ms / std.time.ms_per_s,
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.bufPrint(
        buf,
        "--- RESTORED SNAPSHOT END | {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z ---",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

/// True when nothing has been written to the screen yet: the active area holds
/// no text or background fill, and nothing has scrolled off into history.
/// Used to decide whether a restored snapshot would land on top of a child's
/// startup output. A shell can return the cursor to the origin after printing
/// (`ESC[H`), so cursor position is not on its own a usable test.
pub fn terminalScreenIsUnpainted(screen: *terminal.Screen) bool {
    // A child that only moved the cursor (`ESC[2;2H`) has painted nothing, but
    // restoring would still `scrollClear()` the cursor out from under it while
    // it believes it is at (2,2). Require the origin as well as empty cells.
    if (screen.cursor.x != 0 or screen.cursor.y != 0) return false;

    // A Kitty placement lives in `kitty_images`, not in the page cells, so a
    // child that displayed an image with cursor movement suppressed leaves
    // every cell empty while something is visibly on screen.
    if (comptime terminal_options.kitty_graphics) {
        if (screen.kitty_images.placements.count() > 0) return false;
    }

    // `.screen` spans history plus the active area, so this also catches
    // output that has already scrolled off the top.
    var row_it = screen.pages.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (row_it.next()) |row| {
        for (row.cells(.all)) |cell| {
            if (!cell.isEmpty()) return false;
        }
    }
    return true;
}

pub fn restoreTerminalScrollbackSnapshot(
    terminal_state: *terminal.Terminal,
    snapshot: win32_session_state.ScrollbackSnapshot,
    max_lines_requested: usize,
) !usize {
    const screen = terminal_state.screens.active;

    // The snapshot only survives the shell's startup paint because the
    // `scrollClear` below moves it into history first. With `scrollback-limit
    // = 0` there is no history to move it into, so restoring would report
    // success and then show the user nothing. Refuse instead of lying.
    if (screen.no_scrollback) return error.SnapshotNeedsScrollback;

    // `Surface.init` starts the I/O thread before `createWindowSurface`
    // returns, so the child may already have painted by the time restore runs.
    // Printing a snapshot underneath a live prompt and then scrolling the lot
    // into history would bury the shell's own prompt and leave it painting
    // into a pane it believes is still on screen. Skip instead: a missing
    // snapshot is recoverable, a desynced shell is not.
    //
    // The cursor position alone is not a sufficient test — `"PS> \x1b[H"`
    // leaves prompt cells behind while returning the cursor to the origin —
    // so require the whole active area to be unpainted.
    if (!terminalScreenIsUnpainted(screen)) return error.PaneAlreadyPainted;

    // The checks above prove the pane is *empty*. They do not prove the
    // terminal is in its *initial state*, and restore prints through the
    // ordinary stateful `printString` / `linefeed` path, so any VT state the
    // child set before restore ran changes what those do. Each of the
    // following can be set without painting anything:
    //
    //   - a partial scrolling region (DECSTBM / DECSLRM) makes `linefeed`
    //     scroll inside the region instead of pushing rows into history, so a
    //     snapshot longer than the region eats its own oldest lines;
    //   - a non-main status display makes `Terminal.print` return without
    //     writing (`src/terminal/Terminal.zig:300-304`), so restore would
    //     emit blank linefeeds and still report success;
    //   - a non-default charset remaps the restored text, and a pending
    //     single shift is consumed by the first restored character, so the
    //     child's next shifted character is then misinterpreted;
    //   - autowrap off (DECAWM reset) makes `printString` overwrite the last
    //     column instead of wrapping, so a restored line wider than the pane
    //     loses its tail instead of being kept in history.
    //
    // Enumerating these is the wrong long-term shape and the list has already
    // grown twice under review. The structural fix is to write the snapshot
    // rows straight into the page list instead of through the VT state
    // machine, which makes every one of these irrelevant; that is a larger
    // change than this PR should carry. Until then, refuse rather than
    // corrupt.
    const region = terminal_state.scrolling_region;
    if (region.top != 0 or
        region.left != 0 or
        region.bottom != terminal_state.rows - 1 or
        region.right != terminal_state.cols - 1)
    {
        return error.SnapshotNeedsFullScreen;
    }
    if (terminal_state.status_display != .main) return error.SnapshotNeedsMainDisplay;
    const charset = screen.charset;
    if (charset.single_shift != null or
        charset.gl != .G0 or
        charset.gr != .G2)
    {
        return error.SnapshotNeedsDefaultCharset;
    }
    if (!terminal_state.modes.get(.wraparound)) return error.SnapshotNeedsAutowrap;

    const max_lines = @min(max_lines_requested, win32_session_state.max_scrollback_lines);
    const first_line = snapshot.lines.len - @min(snapshot.lines.len, max_lines);
    var restored_lines: usize = 0;
    for (snapshot.lines[first_line..]) |line| {
        if (line.len > win32_session_state.max_scrollback_line_bytes or
            !sessionScrollbackLineAllowed(line)) continue;
        try printSessionSnapshotLine(terminal_state, line);
        restored_lines += 1;
    }
    if (restored_lines == 0) return 0;

    var marker_buf: [160]u8 = undefined;
    const marker = try formatSessionSnapshotMarker(&marker_buf, snapshot.captured_at_unix_ms);
    try printSessionSnapshotLine(terminal_state, marker);
    try terminal_state.screens.active.scrollClear();
    return restored_lines;
}

pub fn applyProfileConfigByKey(
    config: *configpkg.Config,
    profiles: []const windows_shell.Profile,
    key: []const u8,
) !bool {
    if (startsWithIgnoreCase(key, "ssh:")) return false;
    const index = profileIndexByKey(profiles, key) orelse return false;
    const profile = &profiles[index];
    if (!isSessionRestorableProfile(profile)) return false;
    try applyProfileSurfaceConfig(config, profile);
    return true;
}

/// Session restore relaunches a pane's profile unattended at startup. An SSH
/// profile would dial out with no interaction, so it is refused here.
///
/// The key prefix is rejected before lookup so case variants in a persisted
/// state file cannot bypass the guard. Live SSH profile lookup remains
/// case-sensitive because OpenSSH host aliases are case-sensitive.
pub fn isSessionRestorableProfile(profile: *const windows_shell.Profile) bool {
    return profile.kind != .ssh;
}

pub fn captureSessionScrollback(
    self: *Surface,
    alloc: Allocator,
    max_lines: usize,
    remaining_budget: *usize,
) !?win32_session_state.ScrollbackSnapshot {
    if (max_lines == 0 or self.secure_input_ever_engaged) return null;
    // An end-session save is a sent message. It can arrive while this
    // surface is mid-init or mid-teardown, still in its tab tree but
    // without a live core, or while this thread waits inside a call made
    // under the renderer mutex (the core's copy path holds it across
    // `EmptyClipboard`, which sends to the previous clipboard owner).
    if (!self.core_initialized) return null;
    if (!self.core_surface.renderer_state.mutex.tryLock()) return null;
    defer self.core_surface.renderer_state.mutex.unlock();
    return captureTerminalScrollbackSnapshotAlloc(
        alloc,
        self.app.core_app.alloc,
        self.core_surface.renderer_state.terminal,
        max_lines,
        remaining_budget,
        unixMillis(),
    );
}

pub fn restoreSessionScrollback(
    self: *Surface,
    snapshot: win32_session_state.ScrollbackSnapshot,
    max_lines: usize,
) !bool {
    var scrollbar: terminal.Scrollbar = .zero;
    var restored_lines: usize = 0;
    {
        self.core_surface.renderer_state.mutex.lock();
        defer self.core_surface.renderer_state.mutex.unlock();
        restored_lines = try restoreTerminalScrollbackSnapshot(
            self.core_surface.renderer_state.terminal,
            snapshot,
            max_lines,
        );
        scrollbar = self.core_surface.renderer_state.terminal.screens.active.pages.scrollbar();
    }
    self.setScrollbar(scrollbar) catch |err| {
        log.warn("win32 session restore: snapshot scrollbar sync failed err={}", .{err});
    };
    self.requestRepaint() catch |err| {
        log.warn("win32 session restore: snapshot repaint request failed err={}", .{err});
    };
    return restored_lines > 0;
}

test "win32 a restored tab has the saved shape in the shell model, so closing a pane focuses its neighbour" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var host: Host = undefined;
    var surface_x: Surface = undefined;
    var surface_a: Surface = undefined;
    var surface_b: Surface = undefined;
    var surface_c: Surface = undefined;
    var session: TestSession = .{};
    try session.init(.{
        .core_app = &core_app,
        .app = &app,
        .hosts = &.{.{ .storage = &host, .register = true }},
        .surfaces = &.{
            .{ .storage = &surface_x, .host = &host, .register = true },
            .{ .storage = &surface_a, .host = &host, .register = true },
            .{ .storage = &surface_b, .host = &host, .register = true },
            .{ .storage = &surface_c, .host = &host, .register = true },
        },
        .shell_runtime_initialized = true,
    });
    defer session.deinit();
    const host_hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(host_hwnd);
    host.hwnd = host_hwnd;
    var window = try ShellProjectionSteps.openWindow(&app, &host, &.{&surface_x});
    defer window.deinit();

    // What `Surface.init` does for each restored pane, natively and in the
    // shell model: a new tab, or a split at the pane it is cloned from.
    const Hook = struct {
        var panes: [3]*Surface = undefined;
        var created: usize = 0;

        fn createSurface(
            hook_app: *App,
            _: *const configpkg.Config,
            _: LPCWSTR,
            opts: SurfaceInitOptions,
        ) anyerror!*Surface {
            const alloc = hook_app.core_app.alloc;
            const surface = panes[created];
            created += 1;
            const target = hook_app.registry.findHostById(opts.host_id.?).?;
            var prepared = (try hook_app.prepareShellSurfaceCreate(target, opts)).?;
            defer prepared.deinit();
            if (opts.clone_state_from) |source| {
                const found = hook_app.registry.findTabForSurface(@constCast(source)).?;
                var inserted = try SplitTreeSurface.init(alloc, surface);
                defer inserted.deinit();
                const next = try found.tab.tree.split(alloc, found.tab.findHandle(@constCast(source)).?, opts.split_direction, 0.5, &inserted);
                found.tab.tree.deinit();
                found.tab.tree = next;
                found.tab.focused = found.tab.findHandle(surface).?;
            } else {
                var tab = try Tab.init(alloc, target.nextTabId(), surface);
                errdefer tab.deinit();
                tab.shell_id = prepared.created.tab;
                try target.tabs.append(alloc, tab);
            }
            try prepared.commit(&hook_app.shell_runtime);
            surface.shell_id = prepared.created.pane;
            surface.shell_committed = true;
            return surface;
        }
    };
    Hook.panes = .{ &surface_a, &surface_b, &surface_c };
    Hook.created = 0;
    app.test_create_window_surface = &Hook.createSurface;

    // [A | (B / C)], saved with C selected.
    const nodes = [_]win32_session_state.Node{
        .{ .split = .{ .axis = .horizontal, .ratio = 0.3, .first = 1, .second = 2 } },
        .{ .pane = .{} },
        .{ .split = .{ .axis = .vertical, .ratio = 0.6, .first = 3, .second = 4 } },
        .{ .pane = .{} },
        .{ .pane = .{} },
    };
    var transaction = SessionRestoreTransaction.init(&app);
    const selected = try app.restoreSessionTab(
        .{ .selected_leaf = 2, .layout = .{ .root = 0, .nodes = &nodes } },
        &host,
        1,
        &transaction,
    );
    try std.testing.expectEqual(&surface_c, selected);
    const restored = &host.tabs.items[1];
    try std.testing.expectEqual(@as(?*Surface, &surface_c), restored.focusedSurface());
    try std.testing.expectEqual(@as(f16, 0.3), restored.tree.nodes[0].split.ratio);
    host.active_tab = 1;
    _ = try app.shell_runtime.activatePane(surface_c.shell_id.?);
    try app.validateShellNativeMapping();

    // C exits: B, beside it in the saved tree, takes focus. A model built
    // as a chain of splits off A put C beside A, and focus went to A.
    try ShellProjectionSteps.closePane(&app, restored, &surface_c);
    try std.testing.expectEqual(@as(?*Surface, &surface_b), host.tabs.items[1].focusedSurface());
    try app.validateShellNativeMapping();
}

test "win32 user profiles restore by key, after a rename, with and without a host" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const line = "cmd.exe /k \"C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\Common7\\Tools\\VsDevCmd.bat\" -startdir=none -arch=x64 -host_arch=x64";

    var base = try configpkg.Config.default(alloc);
    defer base.deinit();
    const base_alloc = base._arena.?.allocator();
    try base.@"profile-command".parseCLI(base_alloc, "vs18-cmd: " ++ line);
    try base.@"profile-name".parseCLI(base_alloc, "vs18-cmd: Old label");
    try base.finalize();
    const profiles = try testUserProfileList(alloc, &base);
    defer windows_shell.deinitProfiles(alloc, profiles);

    // The key a session saved, in any case.
    for ([_][]const u8{ "user:vs18-cmd", "USER:VS18-CMD" }) |key| {
        var clone = base.shallowClone(alloc);
        defer clone.deinit();
        try std.testing.expect(try applyProfileConfigByKey(&clone, profiles, key));
        try std.testing.expectEqualStrings("cmd.exe", clone.command.?.direct[0]);
        try std.testing.expectEqualStrings(line, clone._profile_launch.?.command_line);
    }

    // Renaming the label keeps the identity.
    var renamed = try base.clone(alloc);
    defer renamed.deinit();
    try renamed.@"profile-name".parseCLI(renamed._arena.?.allocator(), "vs18-cmd: New label");
    // `%NAME%` reads the `env` lines first, on every path that builds a list.
    try renamed.env.parseCLI(renamed._arena.?.allocator(), "NOCTTY_TEST_TEAM_DIR=C:\\team");
    try renamed.@"profile-env".parseCLI(renamed._arena.?.allocator(), "vs18-cmd: SEEN=%noctty_test_team_dir%\\bin");
    const renamed_profiles = try testUserProfileList(alloc, &renamed);
    defer windows_shell.deinitProfiles(alloc, renamed_profiles);
    try std.testing.expectEqualStrings("New label", renamed_profiles[0].label);
    {
        var clone = renamed.shallowClone(alloc);
        defer clone.deinit();
        try std.testing.expect(try applyProfileConfigByKey(&clone, renamed_profiles, "user:vs18-cmd"));
    }

    // With a host, restore looks the key up in the host's list.
    {
        var host: Host = undefined;
        host.profiles = profiles;
        host.selected_profile = 0;
        var app: App = undefined;
        app.config._default_profile = null;
        var clone = base.shallowClone(alloc);
        defer clone.deinit();
        try std.testing.expect(try app.applyRestoredProfileConfig(&clone, &host, "User:Vs18-Cmd"));
        try std.testing.expectEqualStrings(line, clone._profile_launch.?.command_line);
    }

    // With no host (a restore before the first window, an elevated window
    // from no surface), the list is built from the app config: its user
    // profiles reach the lister, after the local shells, before SSH.
    {
        const lister = struct {
            fn list(a: Allocator, _: bool, user: *const windows_shell.UserProfiles) ![]windows_shell.Profile {
                const shell = try a.alloc(windows_shell.Profile, 1);
                const cmd = try a.alloc([:0]const u8, 1);
                cmd[0] = try a.dupeZ(u8, "C:\\Windows\\System32\\cmd.exe");
                shell[0] = .{ .kind = .cmd, .key = try a.dupe(u8, "cmd.exe"), .label = try a.dupe(u8, "Command Prompt"), .command = .{ .direct = cmd } };
                return try windows_shell.appendUserProfiles(a, shell, user.definitions, windows_shell.ProcessEnvironment{});
            }
        }.list;
        const hostless = try listProfilesForConfig(alloc, &renamed, lister);
        defer windows_shell.deinitProfiles(alloc, hostless);
        try std.testing.expectEqual(@as(usize, 2), hostless.len);
        try std.testing.expectEqualStrings("cmd.exe", hostless[0].key);
        try std.testing.expectEqualStrings("user:vs18-cmd", hostless[1].key);
        try std.testing.expectEqualStrings("New label", hostless[1].label);
        const seen = hostless[1].user.?.env;
        try std.testing.expectEqualStrings("SEEN", seen[seen.len - 1].key);
        try std.testing.expectEqualStrings("C:\\team\\bin", seen[seen.len - 1].value);
        var clone = base.shallowClone(alloc);
        defer clone.deinit();
        try std.testing.expect(try applyProfileConfigByKey(&clone, hostless, "USER:vs18-CMD"));
        try std.testing.expectEqualStrings(line, clone._profile_launch.?.command_line);
    }

    // A removed id restores nothing, so the pane falls back to the default
    // and keeps no launch key; SSH stays refused whatever the list holds.
    var removed = try base.clone(alloc);
    defer removed.deinit();
    try removed.@"profile-command".parseCLI(removed._arena.?.allocator(), "vs18-cmd:");
    try removed.@"profile-command".parseCLI(removed._arena.?.allocator(), "other: other.exe");
    const removed_profiles = try testUserProfileList(alloc, &removed);
    defer windows_shell.deinitProfiles(alloc, removed_profiles);
    for ([_][]const u8{ "user:vs18-cmd", "ssh:prod", "SSH:prod" }) |key| {
        var clone = removed.shallowClone(alloc);
        defer clone.deinit();
        try std.testing.expect(!(try applyProfileConfigByKey(&clone, removed_profiles, key)));
        try std.testing.expect(clone.command == null);
        try std.testing.expect(clone._profile_launch == null);
    }
}

test "win32 Visual Studio profiles restore by key, hidden ones too, with and without a host" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var base = try configpkg.Config.default(alloc);
    defer base.deinit();
    try base.finalize();

    // With no host, the list is built from the app config, whose
    // `visual-studio-profiles` reaches the lister.
    const lister = struct {
        fn list(a: Allocator, _: bool, user: *const windows_shell.UserProfiles) ![]windows_shell.Profile {
            return try testVisualStudioList(a, user.visual_studio);
        }
    }.list;
    const hostless = try listProfilesForConfig(alloc, &base, lister);
    defer windows_shell.deinitProfiles(alloc, hostless);
    try std.testing.expectEqual(@as(usize, 4), hostless.len);
    // 2022's pair is hidden under `newest` and still restores; every pair
    // starts in home.
    for ([_][]const u8{ "vs:486bb794:cmd", "VS:6BB7CFD9:CMD" }) |key| {
        var clone = base.shallowClone(alloc);
        defer clone.deinit();
        try std.testing.expect(try applyProfileConfigByKey(&clone, hostless, key));
        try std.testing.expectEqualStrings("/k", clone.command.?.direct[1]);
        try std.testing.expect(std.mem.startsWith(u8, clone._profile_launch.?.command_line, "C:\\Windows\\System32\\cmd.exe /k \"\"C:\\Program Files\\Microsoft Visual Studio\\"));
        // Home as a path: a bare `.home` on a launch clone would start in
        // noctty's own folder.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (try internal_os.home(&buf)) |home| try std.testing.expectEqualStrings(home, clone.@"working-directory".?.path);
    }
    {
        var clone = base.shallowClone(alloc);
        defer clone.deinit();
        try std.testing.expect(try applyProfileConfigByKey(&clone, hostless, "vs:6bb7cfd9:pwsh"));
        try std.testing.expectEqualStrings("-Command", clone.command.?.direct[2]);
        try std.testing.expect(clone._profile_launch == null);
    }

    // With a host, from its list.
    {
        var host: Host = undefined;
        host.profiles = hostless;
        host.selected_profile = 0;
        var app: App = undefined;
        app.config._default_profile = null;
        var clone = base.shallowClone(alloc);
        defer clone.deinit();
        try std.testing.expect(try app.applyRestoredProfileConfig(&clone, &host, "vs:486bb794:pwsh"));
        try std.testing.expectEqualStrings("-NoExit", clone.command.?.direct[1]);
    }

    // Under `none` there is no such profile: the pane falls back to the
    // default and keeps no launch key.
    var none = try base.clone(alloc);
    defer none.deinit();
    none.@"visual-studio-profiles" = .none;
    const empty = try listProfilesForConfig(alloc, &none, lister);
    defer windows_shell.deinitProfiles(alloc, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    var clone = none.shallowClone(alloc);
    defer clone.deinit();
    try std.testing.expect(!(try applyProfileConfigByKey(&clone, empty, "vs:6bb7cfd9:cmd")));
    try std.testing.expect(clone.command == null);
}

test "win32 a restored pane keeps its own profile over default-profile" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var base = try configpkg.Config.default(alloc);
    defer base.deinit();
    const arena = base._arena.?.allocator();
    try base.@"profile-command".parseCLI(arena, "py: cmd.exe /k py");
    try base.@"profile-env".parseCLI(arena, "py: MODE=profile");
    base.@"default-profile" = "py";
    try base.finalize();

    const pwsh_argv = [_][:0]const u8{"pwsh.exe"};
    var profiles = [_]windows_shell.Profile{.{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &pwsh_argv } }};
    var host: Host = undefined;
    host.profiles = &profiles;
    host.selected_profile = 0;
    var app: App = undefined;
    // Only the field restore reads; `base` stays the owner.
    app.config._default_profile = base._default_profile;
    var clone = base.shallowClone(alloc);
    defer clone.deinit();
    try std.testing.expect(try app.applyRestoredProfileConfig(&clone, &host, "PWSH.EXE"));
    try std.testing.expectEqualStrings("pwsh.exe", clone.command.?.direct[0]);
    // Nothing of the default profile is left to apply.
    try std.testing.expect((try applyDefaultProfileConfig(&clone)) == null);
    try std.testing.expect(clone.env.map.get("MODE") == null);
    try std.testing.expect(clone._profile_launch == null);

    // A pane saved from the default profile restores from the profile the
    // config resolved, though the window's list does not have it (and
    // without a window, without listing the profiles at all).
    var restored = base.shallowClone(alloc);
    defer restored.deinit();
    try std.testing.expect(try app.applyRestoredProfileConfig(&restored, &host, "USER:PY"));
    try std.testing.expectEqualStrings("cmd.exe", restored.command.?.direct[0]);
    try std.testing.expectEqualStrings("profile", restored.env.map.get("MODE") orelse "");
    try std.testing.expectEqualStrings("cmd.exe /k py", if (restored._profile_launch) |launch| launch.command_line else "");
    // SSH stays refused whatever the default profile is.
    var ssh = base.shallowClone(alloc);
    defer ssh.deinit();
    try std.testing.expect(!(try app.applyRestoredProfileConfig(&ssh, &host, "ssh:py")));
}

test "win32 ssh split and session state drop remote cwd" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!shouldInheritSplitWorkingDirectory(true));
    try std.testing.expect(shouldInheritSplitWorkingDirectory(false));
    try std.testing.expect(shouldResetNewTabWorkingDirectory(false, true, true));
    try std.testing.expect(shouldResetNewTabWorkingDirectory(true, true, false));
    try std.testing.expect(!shouldResetNewTabWorkingDirectory(false, false, true));

    var surface: Surface = undefined;
    surface.pwd = "C:\\remote-controlled";
    surface.launched_ssh = true;
    surface.launch_profile_key = null;
    surface.title_override = null;
    surface.tab_title_override = null;
    var tab = try Tab.init(std.testing.allocator, 1, &surface);
    defer tab.deinit();

    var no_scrollback_budget: usize = 0;
    const layout = try App.buildSessionLayout(
        std.testing.allocator,
        &tab,
        .session,
        0,
        &no_scrollback_budget,
    );
    defer std.testing.allocator.free(layout.nodes);
    try std.testing.expect(layout.nodes[0].pane.cwd == null);
}

test "win32 session and layout snapshots drop network and device cwds" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.launched_ssh = false;
    surface.launch_profile_key = null;
    surface.title_override = null;
    surface.tab_title_override = null;
    var tab = try Tab.init(std.testing.allocator, 1, &surface);
    defer tab.deinit();

    const dropped = [_][:0]const u8{
        "\\\\server\\share\\dir",
        "//server/share/dir",
        "\\\\?\\UNC\\server\\share\\dir",
        "\\\\.\\pipe\\x",
        "/\\\\server/share",
    };
    for ([_]App.SnapshotScope{ .session, .layout }) |scope| {
        var no_scrollback_budget: usize = 0;

        surface.pwd = "C:\\Users\\me\\src";
        const kept = try App.buildSessionLayout(
            std.testing.allocator,
            &tab,
            scope,
            0,
            &no_scrollback_budget,
        );
        defer std.testing.allocator.free(kept.nodes);
        try std.testing.expectEqualStrings("C:\\Users\\me\\src", kept.nodes[0].pane.cwd.?);

        for (dropped) |pwd| {
            surface.pwd = pwd;
            const layout = try App.buildSessionLayout(
                std.testing.allocator,
                &tab,
                scope,
                0,
                &no_scrollback_budget,
            );
            defer std.testing.allocator.free(layout.nodes);
            try std.testing.expect(layout.nodes[0].pane.cwd == null);
        }
    }
}

test "win32 session restore refuses ssh profiles regardless of key case" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var base = try configpkg.Config.default(alloc);
    defer base.deinit();

    const argv = try alloc.alloc([:0]const u8, 2);
    argv[0] = try alloc.dupeZ(u8, "C:\\Windows\\System32\\OpenSSH\\ssh.exe");
    argv[1] = try alloc.dupeZ(u8, "prod");
    const cmd_argv = try alloc.alloc([:0]const u8, 1);
    cmd_argv[0] = try alloc.dupeZ(u8, "cmd.exe");
    var profiles = [_]windows_shell.Profile{
        .{
            .kind = .cmd,
            .key = try alloc.dupe(u8, "cmd.exe"),
            .label = try alloc.dupe(u8, "Command Prompt"),
            .command = .{ .direct = cmd_argv },
        },
        .{
            .kind = .ssh,
            .key = try alloc.dupe(u8, "ssh:prod"),
            .label = try alloc.dupe(u8, "SSH: prod"),
            .command = .{ .direct = argv },
        },
    };
    defer for (&profiles) |*profile| profile.deinit(alloc);

    // Live SSH profile lookup is case-sensitive, so a state file naming
    // "SSH:prod" does not resolve `ssh:prod`. The refusal must key on the
    // prefix before lookup, or a case
    // variant could bypass the guard and dial out at startup with no interaction.
    for ([_][]const u8{ "ssh:prod", "SSH:prod", "Ssh:PROD" }) |key| {
        var clone = base.shallowClone(alloc);
        defer clone.deinit();
        if (std.mem.eql(u8, key, "ssh:prod")) {
            try std.testing.expect(profileIndexByKey(&profiles, key) != null);
        } else {
            try std.testing.expect(profileIndexByKey(&profiles, key) == null);
        }
        try std.testing.expect(!(try applyProfileConfigByKey(&clone, &profiles, key)));
        try std.testing.expect(clone.command == null);
    }

    // A local profile still restores.
    var clone = base.shallowClone(alloc);
    defer clone.deinit();
    try std.testing.expect(try applyProfileConfigByKey(&clone, &profiles, "CMD.EXE"));
    try std.testing.expectEqualStrings("cmd.exe", clone.command.?.direct[0]);
}

test "win32 applyProfileConfigByKey applies saved first-pane profile before host exists" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var base = try configpkg.Config.default(std.testing.allocator);
    defer base.deinit();
    const base_alloc = base._arena.?.allocator();
    base.command = .{ .shell = try base_alloc.dupeZ(u8, "pwsh.exe") };

    var clone = base.shallowClone(std.testing.allocator);
    defer clone.deinit();

    var profile: windows_shell.Profile = .{
        .kind = .cmd,
        .key = try std.testing.allocator.dupe(u8, "cmd.exe"),
        .label = try std.testing.allocator.dupe(u8, "Command Prompt"),
        .command = .{ .shell = try std.testing.allocator.dupeZ(u8, "cmd.exe") },
    };
    defer profile.deinit(std.testing.allocator);
    const profiles = [_]windows_shell.Profile{profile};

    try std.testing.expect(try applyProfileConfigByKey(&clone, &profiles, "cmd.exe"));

    try std.testing.expect(clone.command != null);
    try std.testing.expectEqualStrings("cmd.exe", clone.command.?.shell);
}

test "win32 session state scrollback capture enforces line cap budget and secure redaction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback = 1024,
    });
    defer terminal_state.deinit(std.testing.allocator);
    var stream = terminal_state.vtStream();
    defer stream.deinit();
    stream.nextSlice("one\r\ntwo\r\nthree\r\nfour\r\nfive");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var budget = win32_session_state.max_total_scrollback_bytes;
    const snapshot = (try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &terminal_state,
        2,
        &budget,
        123,
    )).?;
    try std.testing.expectEqual(@as(usize, 2), snapshot.lines.len);
    try std.testing.expectEqualStrings("four", snapshot.lines[0]);
    try std.testing.expectEqualStrings("five", snapshot.lines[1]);

    var one_line_budget = win32_session_state.max_total_scrollback_bytes;
    _ = (try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &terminal_state,
        1,
        &one_line_budget,
        124,
    )).?;
    const one_line_cost = win32_session_state.max_total_scrollback_bytes - one_line_budget;
    var shared_budget = one_line_cost;
    const first_budget_snapshot = (try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &terminal_state,
        2,
        &shared_budget,
        125,
    )).?;
    try std.testing.expectEqual(@as(usize, 0), shared_budget);
    const omitted_budget_snapshot = try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &terminal_state,
        2,
        &shared_budget,
        126,
    );
    try std.testing.expect(omitted_budget_snapshot == null);

    const budget_nodes = [_]win32_session_state.Node{
        .{ .split = .{ .axis = .horizontal, .ratio = 0.5, .first = 1, .second = 2 } },
        .{ .pane = .{ .scrollback = first_budget_snapshot } },
        .{ .pane = .{ .scrollback = omitted_budget_snapshot } },
    };
    const budget_tabs = [_]win32_session_state.Tab{.{
        .selected_leaf = 0,
        .layout = .{ .root = 0, .nodes = &budget_nodes },
    }};
    const budget_windows = [_]win32_session_state.Window{.{
        .selected_tab = 0,
        .tabs = &budget_tabs,
    }};
    const budget_encoded = try win32_session_state.encodeAlloc(
        std.testing.allocator,
        .{ .windows = &budget_windows },
    );
    defer std.testing.allocator.free(budget_encoded);
    var budget_parsed = try win32_session_state.parseAlloc(std.testing.allocator, budget_encoded);
    defer budget_parsed.deinit();
    const persisted_budget_nodes = budget_parsed.value.windows[0].tabs[0].layout.nodes;
    try std.testing.expectEqual(@as(usize, 3), persisted_budget_nodes.len);
    try std.testing.expect(persisted_budget_nodes[1].pane.scrollback != null);
    try std.testing.expect(persisted_budget_nodes[2].pane.scrollback == null);

    var overflow_terminal = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 4,
        .rows = 1,
        .max_scrollback = 16,
    });
    defer overflow_terminal.deinit(std.testing.allocator);
    var overflow_stream = overflow_terminal.vtStream();
    defer overflow_stream.deinit();
    overflow_stream.nextSlice("ééé");

    var expensive_terminal = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 4,
        .rows = 1,
        .max_scrollback = 16,
    });
    defer expensive_terminal.deinit(std.testing.allocator);
    var expensive_stream = expensive_terminal.vtStream();
    defer expensive_stream.deinit();
    expensive_stream.nextSlice("\\\\\\\\");

    var following_terminal = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 4,
        .rows = 1,
        .max_scrollback = 16,
    });
    defer following_terminal.deinit(std.testing.allocator);
    var following_stream = following_terminal.vtStream();
    defer following_stream.deinit();
    following_stream.nextSlice("ok");

    const following_cost = win32_session_state.scrollback_snapshot_storage_overhead +
        win32_session_state.scrollbackLineStorageBytes("ok").?;
    var preserved_budget = following_cost;
    try std.testing.expect((try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &overflow_terminal,
        1,
        &preserved_budget,
        127,
    )) == null);
    try std.testing.expectEqual(following_cost, preserved_budget);
    try std.testing.expect((try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &expensive_terminal,
        1,
        &preserved_budget,
        128,
    )) == null);
    try std.testing.expectEqual(following_cost, preserved_budget);
    const following_snapshot = (try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &following_terminal,
        1,
        &preserved_budget,
        129,
    )).?;
    try std.testing.expectEqual(@as(usize, 1), following_snapshot.lines.len);
    try std.testing.expectEqualStrings("ok", following_snapshot.lines[0]);
    try std.testing.expectEqual(@as(usize, 0), preserved_budget);

    var exhausted_budget = win32_session_state.scrollback_snapshot_storage_overhead;
    try std.testing.expect((try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &terminal_state,
        2,
        &exhausted_budget,
        130,
    )) == null);
    try std.testing.expectEqual(@as(usize, 0), exhausted_budget);
    try std.testing.expect((try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &terminal_state,
        2,
        &exhausted_budget,
        131,
    )) == null);
    try std.testing.expectEqual(@as(usize, 0), exhausted_budget);

    var newest_suffix_terminal = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = 16,
    });
    defer newest_suffix_terminal.deinit(std.testing.allocator);
    var newest_suffix_stream = newest_suffix_terminal.vtStream();
    defer newest_suffix_stream.deinit();
    newest_suffix_stream.nextSlice("\\\"\\\"\\\"\\\"\r\nok");

    var newest_suffix_budget = win32_session_state.scrollback_snapshot_storage_overhead + 22;
    const newest_suffix_snapshot = (try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &newest_suffix_terminal,
        2,
        &newest_suffix_budget,
        132,
    )).?;
    try std.testing.expectEqual(@as(usize, 1), newest_suffix_snapshot.lines.len);
    try std.testing.expectEqualStrings("ok", newest_suffix_snapshot.lines[0]);

    var multibyte_terminal = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 32,
    });
    defer multibyte_terminal.deinit(std.testing.allocator);
    var multibyte_stream = multibyte_terminal.vtStream();
    defer multibyte_stream.deinit();
    multibyte_stream.nextSlice(
        "界界界界\r\n界界界界\r\n界界界界\r\n界界界界\r\n" ++
            "界界界界\r\n界界界界\r\n界界界界\r\n終終終終",
    );

    var multibyte_budget = win32_session_state.scrollback_snapshot_storage_overhead + 88;
    const multibyte_snapshot = (try captureTerminalScrollbackSnapshotAlloc(
        arena.allocator(),
        std.testing.allocator,
        &multibyte_terminal,
        8,
        &multibyte_budget,
        133,
    )).?;
    try std.testing.expect(multibyte_snapshot.lines.len > 0);
    try std.testing.expect(multibyte_snapshot.lines.len < 8);
    try std.testing.expectEqualStrings(
        "終終終終",
        multibyte_snapshot.lines[multibyte_snapshot.lines.len - 1],
    );

    var core_app: CoreApp = undefined;
    core_app.alloc = std.testing.allocator;
    var app: App = undefined;
    app.core_app = &core_app;
    app.registry.hosts = .empty;
    defer app.registry.hosts.deinit(std.testing.allocator);

    var renderer_mutex: std.Thread.Mutex = .{};
    var secure_surface: Surface = .{ .app = &app };
    secure_surface.core_surface.renderer_state = .{
        .mutex = &renderer_mutex,
        .terminal = &terminal_state,
    };
    try secure_surface.setSecureInput(.on);
    try secure_surface.setSecureInput(.off);
    try std.testing.expect(secure_surface.secure_input_ever_engaged);

    var normal_surface: Surface = .{ .app = &app };
    normal_surface.core_surface.renderer_state = .{
        .mutex = &renderer_mutex,
        .terminal = &terminal_state,
    };
    // The renderer state above stands in for a live core; capture skips a
    // surface without one.
    normal_surface.core_initialized = true;
    var host: Host = .{ .app = &app, .id = 1 };
    defer {
        for (host.tabs.items) |*tab| tab.deinit();
        host.tabs.deinit(std.testing.allocator);
    }
    secure_surface.host = &host;
    normal_surface.host = &host;
    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &secure_surface));
    var inserted = try SplitTreeSurface.init(std.testing.allocator, &normal_surface);
    defer inserted.deinit();
    const split_tree = try host.tabs.items[0].tree.split(
        std.testing.allocator,
        .root,
        .right,
        0.5,
        &inserted,
    );
    host.tabs.items[0].tree.deinit();
    host.tabs.items[0].tree = split_tree;
    try app.registry.addHost(std.testing.allocator, &host);

    var state_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state_arena.deinit();
    const saved_state = try app.buildSessionState(state_arena.allocator(), 2);
    const saved_nodes = saved_state.windows[0].tabs[0].layout.nodes;
    try std.testing.expectEqual(@as(usize, 3), saved_nodes.len);
    try std.testing.expect(saved_nodes[1].pane.scrollback != null);
    try std.testing.expect(saved_nodes[2].pane.scrollback == null);
    const redacted_encoded = try win32_session_state.encodeAlloc(std.testing.allocator, saved_state);
    defer std.testing.allocator.free(redacted_encoded);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, redacted_encoded, "\"scrollback\""));

    // A display-change or end-session save can arrive while a surface is
    // still in its tab but its core is gone (mid-teardown) or not yet up.
    normal_surface.core_initialized = false;
    const torn_down_state = try app.buildSessionState(state_arena.allocator(), 2);
    for (torn_down_state.windows[0].tabs[0].layout.nodes) |node| switch (node) {
        .pane => |pane| try std.testing.expect(pane.scrollback == null),
        .split => {},
    };
}

test "win32 session scrollback restore marks snapshots and rejects control lines" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var marker_buf: [160]u8 = undefined;
    const marker = try formatSessionSnapshotMarker(&marker_buf, 0);
    try std.testing.expect(marker.len < 60);
    try std.testing.expectEqualStrings(
        "--- RESTORED SNAPSHOT END | 1970-01-01T00:00:00Z ---",
        marker,
    );
    var fallback_marker_buf: [160]u8 = undefined;
    const fallback_marker = try formatSessionSnapshotMarker(
        &fallback_marker_buf,
        253_402_300_800_000,
    );
    try std.testing.expect(fallback_marker.len < 60);
    try std.testing.expectEqualStrings(
        "--- SNAPSHOT END | Unix ms 253402300800000 ---",
        fallback_marker,
    );

    var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 65,
        .rows = 8,
        .max_scrollback = 1024,
    });
    defer terminal_state.deinit(std.testing.allocator);
    try terminal_state.setTitle("original title");

    const lines = [_][]const u8{
        "safe snapshot line",
        "tab\tline",
        "escape\x1b]2;tampered title\x07payload",
        "newline\ncontrol payload",
        "delete\x7fpayload",
        "c1\xc2\x9bpayload",
    };
    const restored_lines = try restoreTerminalScrollbackSnapshot(
        &terminal_state,
        .{
            .captured_at_unix_ms = 0,
            .lines = &lines,
        },
        lines.len,
    );
    try std.testing.expectEqual(@as(usize, 2), restored_lines);

    const screen = try terminal_state.screens.active.dumpStringAlloc(
        std.testing.allocator,
        .{ .screen = .{} },
    );
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "safe snapshot line") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "tab") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "payload") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        screen,
        "--- RESTORED SNAPSHOT END | 1970-01-01T00:00:00Z ---",
    ) != null);
    try std.testing.expectEqualStrings("original title", terminal_state.getTitle().?);

    var rejected_terminal = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 100,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer rejected_terminal.deinit(std.testing.allocator);
    const rejected_lines = [_][]const u8{
        "escape\x1b]2;tampered title\x07payload",
        "newline\ncontrol payload",
        "delete\x7fpayload",
        "c1\xc2\x9bpayload",
    };
    try std.testing.expectEqual(@as(usize, 0), try restoreTerminalScrollbackSnapshot(
        &rejected_terminal,
        .{ .captured_at_unix_ms = 0, .lines = &rejected_lines },
        rejected_lines.len,
    ));
    const rejected_plain = try rejected_terminal.plainString(std.testing.allocator);
    defer std.testing.allocator.free(rejected_plain);
    try std.testing.expect(std.mem.indexOf(u8, rejected_plain, "SNAPSHOT END") == null);

    var disabled_terminal = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 100,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer disabled_terminal.deinit(std.testing.allocator);
    const stale_lines = [_][]const u8{"stale snapshot must stay on disk only"};
    try std.testing.expectEqual(@as(usize, 0), try restoreTerminalScrollbackSnapshot(
        &disabled_terminal,
        .{ .captured_at_unix_ms = 0, .lines = &stale_lines },
        0,
    ));
    const disabled_plain = try disabled_terminal.plainString(std.testing.allocator);
    defer std.testing.allocator.free(disabled_plain);
    try std.testing.expect(std.mem.indexOf(u8, disabled_plain, "stale snapshot") == null);
    try std.testing.expect(std.mem.indexOf(u8, disabled_plain, "SNAPSHOT END") == null);

    var lowered_terminal = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 100,
        .rows = 6,
        .max_scrollback = 1024,
    });
    defer lowered_terminal.deinit(std.testing.allocator);
    const lowered_lines = [_][]const u8{ "oldest", "middle", "newest" };
    try std.testing.expectEqual(@as(usize, 2), try restoreTerminalScrollbackSnapshot(
        &lowered_terminal,
        .{ .captured_at_unix_ms = 0, .lines = &lowered_lines },
        2,
    ));
    const lowered_screen = try lowered_terminal.screens.active.dumpStringAlloc(
        std.testing.allocator,
        .{ .screen = .{} },
    );
    defer std.testing.allocator.free(lowered_screen);
    try std.testing.expect(std.mem.indexOf(u8, lowered_screen, "oldest") == null);
    try std.testing.expect(std.mem.indexOf(u8, lowered_screen, "middle") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered_screen, "newest") != null);
    try std.testing.expect(std.mem.indexOf(u8, lowered_screen, "SNAPSHOT END") != null);
}

test "win32 session scrollback restore survives pwsh ConPTY startup repaint" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 8,
        .max_scrollback = 1024,
    });
    defer terminal_state.deinit(std.testing.allocator);

    const lines = [_][]const u8{
        "L01", "L02", "L03", "L04", "L05", "L06",
        "L07", "L08", "L09", "L10", "L11", "L12",
    };
    try std.testing.expectEqual(@as(usize, lines.len), try restoreTerminalScrollbackSnapshot(
        &terminal_state,
        .{ .captured_at_unix_ms = 0, .lines = &lines },
        lines.len,
    ));

    var stream = terminal_state.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?9001h\x1b[?1004h\x1b[?25l\x1b[2J\x1b[m\x1b[H");

    const screen = try terminal_state.screens.active.dumpStringAlloc(
        std.testing.allocator,
        .{ .screen = .{} },
    );
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "L12") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "--- RESTORED SNAPSHOT END |") != null);
}

test "win32 session scrollback restore refuses panes it cannot restore safely" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const lines = [_][]const u8{ "L01", "L02" };
    const snapshot: win32_session_state.ScrollbackSnapshot = .{
        .captured_at_unix_ms = 0,
        .lines = &lines,
    };

    // `scrollback-limit = 0`: `scrollClear` has nowhere to move the snapshot,
    // so a "successful" restore would leave the user with nothing.
    {
        var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
            .cols = 80,
            .rows = 8,
            .max_scrollback = 0,
        });
        defer terminal_state.deinit(std.testing.allocator);
        try std.testing.expect(terminal_state.screens.active.no_scrollback);
        try std.testing.expectError(
            error.SnapshotNeedsScrollback,
            restoreTerminalScrollbackSnapshot(&terminal_state, snapshot, lines.len),
        );
    }

    // The child painted before restore ran. Restoring here would scroll the
    // shell's own prompt into history and desync it from the pane.
    {
        var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
            .cols = 80,
            .rows = 8,
            .max_scrollback = 1024,
        });
        defer terminal_state.deinit(std.testing.allocator);

        var stream = terminal_state.vtStream();
        defer stream.deinit();
        stream.nextSlice("PS C:\\src> ");
        try std.testing.expect(terminal_state.screens.active.cursor.x != 0);

        try std.testing.expectError(
            error.PaneAlreadyPainted,
            restoreTerminalScrollbackSnapshot(&terminal_state, snapshot, lines.len),
        );

        const screen = try terminal_state.screens.active.dumpStringAlloc(
            std.testing.allocator,
            .{ .screen = .{} },
        );
        defer std.testing.allocator.free(screen);
        try std.testing.expect(std.mem.indexOf(u8, screen, "PS C:\\src>") != null);
        try std.testing.expect(std.mem.indexOf(u8, screen, "L01") == null);
        try std.testing.expect(std.mem.indexOf(u8, screen, "SNAPSHOT END") == null);
    }

    // The child only moved the cursor. Nothing is painted, but restoring would
    // scroll the cursor out from under a shell that thinks it is at (2,2).
    {
        var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
            .cols = 80,
            .rows = 8,
            .max_scrollback = 1024,
        });
        defer terminal_state.deinit(std.testing.allocator);

        var stream = terminal_state.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[2;2H");

        try std.testing.expectError(
            error.PaneAlreadyPainted,
            restoreTerminalScrollbackSnapshot(&terminal_state, snapshot, lines.len),
        );
    }

    // A partial scrolling region leaves the pane unpainted and the cursor at
    // the origin, but printing into it would scroll within the region instead
    // of building history, so the snapshot would eat its own oldest lines.
    {
        var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
            .cols = 80,
            .rows = 8,
            .max_scrollback = 1024,
        });
        defer terminal_state.deinit(std.testing.allocator);

        var stream = terminal_state.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[2;5r");
        try std.testing.expect(terminalScreenIsUnpainted(terminal_state.screens.active));

        try std.testing.expectError(
            error.SnapshotNeedsFullScreen,
            restoreTerminalScrollbackSnapshot(&terminal_state, snapshot, lines.len),
        );
    }

    // VT state the child can set without painting: each leaves the pane empty
    // and the cursor at the origin, and each would corrupt the restore in a
    // different way. Asserting `terminalScreenIsUnpainted` first in every case
    // pins that these checks do work the painted-pane predicate cannot.
    {
        const Case = struct {
            bytes: []const u8 = "",
            status_line: bool = false,
            want: anyerror,
        };
        for ([_]Case{
            // SS2: a pending single shift is consumed by the first restored
            // character, remapping it and desyncing the child's next one.
            .{ .bytes = "\x1bN", .want = error.SnapshotNeedsDefaultCharset },
            // SO: a locking shift remaps every restored character.
            .{ .bytes = "\x0e", .want = error.SnapshotNeedsDefaultCharset },
            // DECAWM reset: a restored line wider than the pane would
            // overwrite its last column instead of wrapping into history.
            .{ .bytes = "\x1b[?7l", .want = error.SnapshotNeedsAutowrap },
            // DECSASD. Set directly rather than through the stream: this fork
            // does not parse the sequence, but `Terminal.print` still returns
            // without writing whenever `status_display != .main`, so restore
            // would emit blank linefeeds and report success.
            .{ .status_line = true, .want = error.SnapshotNeedsMainDisplay },
        }) |case| {
            var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
                .cols = 80,
                .rows = 8,
                .max_scrollback = 1024,
            });
            defer terminal_state.deinit(std.testing.allocator);

            var stream = terminal_state.vtStream();
            defer stream.deinit();
            if (case.bytes.len > 0) stream.nextSlice(case.bytes);
            if (case.status_line) terminal_state.status_display = .status_line;
            try std.testing.expect(terminalScreenIsUnpainted(terminal_state.screens.active));

            try std.testing.expectError(
                case.want,
                restoreTerminalScrollbackSnapshot(&terminal_state, snapshot, lines.len),
            );
        }
    }

    // The child painted and then homed the cursor. Cursor position alone would
    // call this pane pristine, so the predicate must look at the cells.
    {
        var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
            .cols = 80,
            .rows = 8,
            .max_scrollback = 1024,
        });
        defer terminal_state.deinit(std.testing.allocator);

        var stream = terminal_state.vtStream();
        defer stream.deinit();
        stream.nextSlice("PS C:\\src> \x1b[H");
        try std.testing.expectEqual(@as(usize, 0), terminal_state.screens.active.cursor.x);
        try std.testing.expectEqual(@as(usize, 0), terminal_state.screens.active.cursor.y);

        try std.testing.expectError(
            error.PaneAlreadyPainted,
            restoreTerminalScrollbackSnapshot(&terminal_state, snapshot, lines.len),
        );
    }

    // A pane that pwsh has cleared but not yet prompted into is still eligible:
    // its startup `ESC[2J ESC[H` leaves no painted cells.
    {
        var terminal_state = try terminal.Terminal.init(std.testing.allocator, .{
            .cols = 80,
            .rows = 8,
            .max_scrollback = 1024,
        });
        defer terminal_state.deinit(std.testing.allocator);

        var stream = terminal_state.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[?9001h\x1b[?1004h\x1b[?25l\x1b[2J\x1b[m\x1b[H");

        try std.testing.expectEqual(
            @as(usize, lines.len),
            try restoreTerminalScrollbackSnapshot(&terminal_state, snapshot, lines.len),
        );
    }
}

test "win32 session save skips every tab of the quick terminal host" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var app: App = undefined;
    app.registry.hosts = .empty;
    defer app.registry.hosts.deinit(std.testing.allocator);

    var quick_host: Host = .{
        .app = &app,
        .id = 1,
        .quick_terminal = true,
    };
    var host: Host = .{
        .app = &app,
        .id = 2,
    };
    defer {
        for (quick_host.tabs.items) |*tab| tab.deinit();
        quick_host.tabs.deinit(std.testing.allocator);
        for (host.tabs.items) |*tab| tab.deinit();
        host.tabs.deinit(std.testing.allocator);
    }

    // Two tabs in the quick terminal, neither the one it was created with:
    // what is left once that first pane closes.
    var first: Surface = undefined;
    var second: Surface = undefined;
    try quick_host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &first));
    try quick_host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 2, &second));
    try app.registry.addHost(std.testing.allocator, &quick_host);

    const state = try app.buildSessionState(std.testing.allocator, 0);
    defer std.testing.allocator.free(state.windows);
    try std.testing.expectEqual(@as(usize, 0), state.windows.len);
    try std.testing.expectEqual(@as(usize, 0), App.hostSessionTabs(&quick_host).len);
    var no_budget: usize = 0;
    try std.testing.expectError(
        error.EmptyTabs,
        App.buildSessionWindow(std.testing.allocator, &quick_host, .layout, 0, &no_budget),
    );

    var normal_surface: Surface = undefined;
    normal_surface.pwd = null;
    normal_surface.launch_profile_key = null;
    normal_surface.title_override = null;
    normal_surface.tab_title_override = null;
    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 3, &normal_surface));
    try app.registry.addHost(std.testing.allocator, &host);

    const mixed_state = try app.buildSessionState(std.testing.allocator, 0);
    defer {
        for (mixed_state.windows) |window| {
            for (window.tabs) |tab| std.testing.allocator.free(tab.layout.nodes);
            std.testing.allocator.free(window.tabs);
        }
        std.testing.allocator.free(mixed_state.windows);
    }
    try std.testing.expectEqual(@as(usize, 1), mixed_state.windows.len);
    try std.testing.expectEqual(@as(usize, 1), mixed_state.windows[0].tabs.len);
    try std.testing.expectEqual(@as(usize, 0), mixed_state.windows[0].selected_tab);
}

test "security regression win32 session save drops one hostile pane field" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var app: App = undefined;
    app.registry.hosts = .empty;
    defer app.registry.hosts.deinit(std.testing.allocator);

    var host: Host = .{
        .app = &app,
        .id = 1,
    };
    defer {
        for (host.tabs.items) |*tab| tab.deinit();
        host.tabs.deinit(std.testing.allocator);
    }

    var surface: Surface = undefined;
    surface.launched_ssh = false;
    surface.pwd = "C:\\src\\noctty";
    surface.launch_profile_key = "pwsh";
    surface.title_override = "Build\x1b\x07";
    surface.tab_title_override = "Docs";
    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &surface));
    try app.registry.addHost(std.testing.allocator, &host);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state = try app.buildSessionState(arena.allocator(), 0);
    const encoded = try win32_session_state.encodeAlloc(std.testing.allocator, state);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"title_override\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\\u001b") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"cwd\":\"C:\\\\src\\\\noctty\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"profile\":\"pwsh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"tab_title_override\":\"Docs\"") != null);

    const hostile_file =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"title_override":"Build\u001b\u0007"}}]}}]}]}
    ;
    try std.testing.expectError(
        error.InvalidPaneText,
        win32_session_state.parseAlloc(std.testing.allocator, hostile_file),
    );
}

test "win32 safe mode never mutates saved session state" {
    try std.testing.expect(!sessionStatePolicyAllows(true, .default));
    try std.testing.expect(!sessionStatePolicyAllows(true, .always));
    try std.testing.expect(!sessionStatePolicyAllows(true, .never));
    try std.testing.expect(sessionStatePolicyAllows(false, .default));
    try std.testing.expect(sessionStatePolicyAllows(false, .always));
    try std.testing.expect(!sessionStatePolicyAllows(false, .never));
}

test "win32 explicit startup flows bypass session restore" {
    try std.testing.expect(sessionRestorePolicyAllows(false, .default, true, false, false, false));
    try std.testing.expect(sessionRestorePolicyAllows(false, .always, true, false, false, false));
    try std.testing.expect(!sessionRestorePolicyAllows(false, .default, true, true, false, false));
    try std.testing.expect(!sessionRestorePolicyAllows(false, .default, true, false, true, false));
    try std.testing.expect(!sessionRestorePolicyAllows(false, .default, true, false, false, true));
    try std.testing.expect(!sessionRestorePolicyAllows(false, .always, false, false, false, false));
    try std.testing.expect(!sessionRestorePolicyAllows(true, .always, true, false, false, false));
    try std.testing.expect(!sessionRestorePolicyAllows(false, .never, true, false, false, false));
    try std.testing.expect(!sessionRestorePolicyAllows(false, .always, false, true, true, true));
}

test "win32 session state is saved only by the process that owns it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const state_path = try std.fs.path.join(std.testing.allocator, &.{ root, "session-state.json" });
    defer std.testing.allocator.free(state_path);

    var app: App = undefined;
    app.safe_mode = false;
    app.embedding_mode = false;
    app.startup_profile_picker = false;
    app.explicit_startup_working_directory = false;
    app.config.@"window-save-state" = .always;
    app.config.@"initial-window" = true;
    app.config.@"initial-command" = null;
    app.config._default_profile_cli = null;

    // A launch that forwarded to the primary, lost the IPC race or failed
    // before its first window never took the session, and must not save
    // its own windows over it.
    app.session_owner = null;
    try std.testing.expect(!app.sessionStateEnabled());

    app.session_owner = (try SessionOwnerLock.acquire(std.testing.allocator, state_path)).?;
    defer app.releaseSessionOwnership();
    try std.testing.expect(app.sessionStateEnabled());

    // A default-terminal handoff server never restored the workspace, so it
    // must not replace or delete it.
    app.embedding_mode = true;
    try std.testing.expect(!app.sessionStateEnabled());
    app.embedding_mode = false;

    // Neither may an explicit-directory launch (Explorer's "Open noctty
    // here" verb, a jump-list folder), which never restored it either.
    app.explicit_startup_working_directory = true;
    try std.testing.expect(!app.sessionStateEnabled());
    app.explicit_startup_working_directory = false;

    // Nor a jump-list link to a user profile, which names it with
    // `--default-profile=` and, when the profile has a directory of its
    // own, carries no `--working-directory=`.
    {
        const running = app.config;
        defer app.config = running;
        inline for (.{
            .{ &[_][:0]const u8{ "--single-instance=false", "--command=", "--initial-command=", "--default-profile=user:py" }, false },
            .{ &[_][:0]const u8{ "--single-instance=false", "--command=", "--initial-command=" }, true },
            .{ &[_][:0]const u8{ "--default-profile=user:py", "--default-profile=" }, true },
        }) |case| {
            var config = try configpkg.Config.default(std.testing.allocator);
            defer config.deinit();
            var args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(case[0]) };
            try config.loadIter(std.testing.allocator, &args);
            try config.finalize();
            config.@"window-save-state" = .always;
            app.config = config;
            try std.testing.expectEqual(case[1], app.sessionRestoreEligible());
            try std.testing.expectEqual(case[1], app.sessionStateEnabled());
        }
    }

    // A reload to window-save-state = never still stops the owner.
    app.config.@"window-save-state" = .never;
    try std.testing.expect(!app.sessionStateEnabled());
    app.config.@"window-save-state" = .always;
    try std.testing.expect(app.sessionStateEnabled());
}

test "win32 a structural change arms one session checkpoint, only in the session's owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const state_path = try std.fs.path.join(std.testing.allocator, &.{ root, "session-state.json" });
    defer std.testing.allocator.free(state_path);

    var core_app: CoreApp = undefined;
    core_app.alloc = std.testing.allocator;
    var app: App = undefined;
    app.core_app = &core_app;
    app.safe_mode = false;
    app.embedding_mode = false;
    app.startup_profile_picker = false;
    app.explicit_startup_working_directory = false;
    app.config.@"window-save-state" = .always;
    app.config.@"initial-window" = true;
    app.config.@"initial-command" = null;
    app.config._default_profile_cli = null;
    app.session_state_excluded_for_elevation = false;
    app.session_ending = false;
    app.session_state_saved_before_last_host_close = false;
    app.session_checkpoint_ms = null;
    app.session_checkpoint_timer_id = null;
    defer app.stopSessionCheckpointTimer();
    const persist = [_]win32_shell.effect.Effect{.persist_session};

    // A process that does not own the saved session, or is still restoring
    // it, arms nothing.
    app.session_owner = null;
    app.applyShellEffects(&persist, .{});
    try std.testing.expectEqual(@as(?UINT_PTR, null), app.session_checkpoint_timer_id);

    app.session_owner = (try SessionOwnerLock.acquire(std.testing.allocator, state_path)).?;
    defer app.releaseSessionOwnership();
    app.applyShellEffects(&persist, .{});
    const armed = app.session_checkpoint_timer_id.?;
    // The next change in a burst restarts the same timer.
    app.applyShellEffects(&persist, .{});
    try std.testing.expectEqual(armed, app.session_checkpoint_timer_id.?);

    // When it fires, the session is saved once and the timer stops. (A
    // test has no LOCALAPPDATA, so nothing reaches the disk.)
    app.onSessionCheckpointTimer();
    try std.testing.expectEqual(@as(?UINT_PTR, null), app.session_checkpoint_timer_id);
    try std.testing.expect(app.session_checkpoint_ms != null);
}

test "win32 a session a newer build wrote, or one too large to be ours, is left alone and never owned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const state_path = try std.fs.path.join(std.testing.allocator, &.{ root, "session-state.json" });
    defer std.testing.allocator.free(state_path);

    var core_app: CoreApp = undefined;
    core_app.alloc = std.testing.allocator;
    var app: App = undefined;
    app.core_app = &core_app;
    app.session_owner = null;
    app.session_state_left_alone = false;

    // A field a later build added within this version loads.
    const added = "{\"schema_version\":1,\"added_later\":1,\"windows\":[]}";
    try tmp.dir.writeFile(.{ .sub_path = "session-state.json", .data = added });
    var loaded = (try app.loadSessionStateAt(state_path)).?;
    loaded.deinit();
    try std.testing.expect(!app.session_state_left_alone);

    // A newer schema is neither restored, quarantined nor owned.
    const newer = "{\"schema_version\":2,\"windows\":[{\"layout_v2\":true}]}";
    try tmp.dir.writeFile(.{ .sub_path = "session-state.json", .data = newer });
    try std.testing.expect((try app.loadSessionStateAt(state_path)) == null);
    try std.testing.expect(app.session_state_left_alone);
    const lock = (try SessionOwnerLock.acquire(std.testing.allocator, state_path)).?;
    app.adoptSessionOwner(lock);
    try std.testing.expect(app.session_owner == null);
    const kept = try tmp.dir.readFileAlloc(std.testing.allocator, "session-state.json", 1024);
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings(newer, kept);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("session-state.json.corrupt", .{}));
    // The lock was given back, so the build that wrote the file can take it.
    const next = (try SessionOwnerLock.acquire(std.testing.allocator, state_path)).?;
    next.release();

    // A file that cannot be read now is not replaced either: it may be a
    // newer build's, held for a moment.
    app.session_state_left_alone = false;
    try tmp.dir.makeDir("session-state.d");
    const unreadable = try std.fs.path.join(std.testing.allocator, &.{ root, "session-state.d" });
    defer std.testing.allocator.free(unreadable);
    try std.testing.expect(std.meta.isError(app.loadSessionStateAt(unreadable)));
    try std.testing.expect(app.session_state_left_alone);

    // So is a file larger than this build ever writes.
    app.session_state_left_alone = false;
    {
        var file = try tmp.dir.createFile("session-state.json", .{});
        defer file.close();
        const chunk = [_]u8{' '} ** 4096;
        var remaining: usize = win32_session_persistence.default_max_state_bytes + 1;
        while (remaining > 0) {
            const count = @min(remaining, chunk.len);
            try file.writeAll(chunk[0..count]);
            remaining -= count;
        }
    }
    try std.testing.expect((try app.loadSessionStateAt(state_path)) == null);
    try std.testing.expect(app.session_state_left_alone);

    // Otherwise the process owns what it restored.
    app.session_state_left_alone = false;
    const mine = (try SessionOwnerLock.acquire(std.testing.allocator, state_path)).?;
    app.adoptSessionOwner(mine);
    try std.testing.expect(app.session_owner != null);
    app.releaseSessionOwnership();
}

test "win32 a snapshot with no session window leaves the saved session alone" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const saved = "{\"schema_version\":1,\"windows\":[]}";
    try tmp.dir.writeFile(.{ .sub_path = "session-state.json", .data = saved });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "session-state.json");
    defer std.testing.allocator.free(path);

    // A quick terminal with a tab, and a window kept empty for undo after
    // its last tab closed: neither holds anything the session records.
    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var quick: Host = undefined;
    var emptied: Host = undefined;
    var surface: Surface = undefined;
    var session: TestSession = .{};
    try session.init(.{
        .core_app = &core_app,
        .app = &app,
        .hosts = &.{
            .{ .storage = &quick, .id = 1, .register = true },
            .{ .storage = &emptied, .id = 2, .register = true },
        },
        .surfaces = &.{.{ .storage = &surface, .host = &quick, .register = true }},
        .tabs = &.{.{ .host = &quick, .surface = &surface, .id = 1 }},
    });
    defer session.deinit();
    quick.quick_terminal = true;
    try std.testing.expect(!app.hasSessionWindows());

    // Before #497 the owner's `.final` save of such a snapshot deleted the
    // file, and so did `terminate` after every close that left the save to
    // it. The session's last window saves as it goes now, so an empty
    // snapshot writes nothing and deletes nothing, checkpoint or final.
    try std.testing.expect(!app.writeSessionStateAt(path));
    const kept = try tmp.dir.readFileAlloc(std.testing.allocator, "session-state.json", 256);
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings(saved, kept);
}

test "win32 session owner lock admits one live owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    // The directory does not exist yet on a first run.
    const state_path = try std.fs.path.join(std.testing.allocator, &.{ root, "noctty", "session-state.json" });
    defer std.testing.allocator.free(state_path);

    const first = (try SessionOwnerLock.acquire(std.testing.allocator, state_path)).?;
    // A second instance (single-instance = false) finds it taken.
    try std.testing.expect((try SessionOwnerLock.acquire(std.testing.allocator, state_path)) == null);
    first.release();
    // Once the owner is gone the next launch takes over.
    const next = (try SessionOwnerLock.acquire(std.testing.allocator, state_path)).?;
    next.release();
}

test "win32 session restore transaction preserves first surface state" {
    var core_app: CoreApp = undefined;
    core_app.first = true;
    var app: App = undefined;
    app.core_app = &core_app;

    var rolled_back = SessionRestoreTransaction.init(&app);
    core_app.first = false;
    rolled_back.rollback();
    try std.testing.expect(core_app.first);

    var committed = SessionRestoreTransaction.init(&app);
    core_app.first = false;
    committed.commit();
    committed.rollback();
    try std.testing.expect(!core_app.first);
}

test "win32 session state window rect requires complete geometry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?RECT, null), try App.sessionStateWindowRect(.{
        .selected_tab = 0,
        .tabs = &.{},
    }));
    try std.testing.expectError(error.InvalidWindowRect, App.sessionStateWindowRect(.{
        .x = 10,
        .selected_tab = 0,
        .tabs = &.{},
    }));

    const rect = (try App.sessionStateWindowRect(.{
        .x = 10,
        .y = 20,
        .width = 300,
        .height = 200,
        .selected_tab = 0,
        .tabs = &.{},
    })).?;
    try std.testing.expectEqual(@as(i32, 10), rect.left);
    try std.testing.expectEqual(@as(i32, 20), rect.top);
    try std.testing.expectEqual(@as(i32, 310), rect.right);
    try std.testing.expectEqual(@as(i32, 220), rect.bottom);
}

test "win32 fullscreen session placement retains captured geometry after lookup failure" {
    var surface: Surface = undefined;
    const normal: RECT = .{ .left = 100, .top = 200, .right = 740, .bottom = 680 };
    surface.restore_rect = normal;
    surface.restore_placement = std.mem.zeroes(WINDOWPLACEMENT);
    surface.restore_placement.showCmd = 1; // SW_SHOWNORMAL
    surface.restore_monitor = .{
        .monitor = @ptrFromInt(1),
        .dpi = 96,
        .info = .{
            .cbSize = @sizeOf(MONITORINFO),
            .rcMonitor = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
            .rcWork = .{ .left = 48, .top = 0, .right = 1920, .bottom = 1080 },
            .dwFlags = 0,
        },
    };
    var placed = App.sessionFullscreenWindowPlacement(&surface, error.Unexpected, null).?;
    try std.testing.expect(placed.fullscreen and !placed.maximized);
    try std.testing.expectEqualDeep(normal, placed.rect.?);

    // A captured maximized normal rect is in the source's workspace.
    surface.restore_placement.showCmd = c.SW_MAXIMIZE;
    surface.restore_placement.rcNormalPosition = .{ .left = 52, .top = 200, .right = 692, .bottom = 680 };
    placed = App.sessionFullscreenWindowPlacement(&surface, error.Unexpected, null).?;
    try std.testing.expect(placed.fullscreen and placed.maximized);
    try std.testing.expectEqualDeep(normal, placed.rect.?);

    // No trustworthy return rect: omit placement instead of persisting
    // fullscreen with an invented normal rect or saving popup bounds.
    surface.restore_placement.rcNormalPosition = std.mem.zeroes(RECT);
    try std.testing.expect(App.sessionFullscreenWindowPlacement(&surface, error.Unexpected, null) == null);
    surface.restore_placement.showCmd = 1; // SW_SHOWNORMAL
    surface.restore_rect = std.mem.zeroes(RECT);
    try std.testing.expect(App.sessionFullscreenWindowPlacement(&surface, error.Unexpected, null) == null);
}

test "win32 session placement saves the normal rect in screen coordinates for every window state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            const surface = try placementTestSurface(&app, 120, 140);
            defer _ = sys.DestroyWindow(surface.hwnd.?);
            const hwnd = surface.hwnd.?;
            var host: Host = .{ .app = &app, .id = 1, .hwnd = hwnd };
            _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
            var normal: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(hwnd, &normal) != 0);

            var placed = App.sessionWindowPlacement(&host).?;
            try std.testing.expectEqualDeep(normal, placed.rect.?);
            try std.testing.expect(!placed.maximized);

            // Maximized, the rect is still the one to un-maximize to.
            _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
            placed = App.sessionWindowPlacement(&host).?;
            try std.testing.expectEqualDeep(normal, placed.rect.?);
            try std.testing.expect(placed.maximized);

            // With a taskbar on the left, Windows reports that normal rect
            // relative to the work area, which starts 48 px in: the file
            // gets screen coordinates.
            const left_taskbar: MONITORINFO = .{
                .cbSize = @sizeOf(MONITORINFO),
                .rcMonitor = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
                .rcWork = .{ .left = 48, .top = 0, .right = 1920, .bottom = 1080 },
                .dwFlags = 0,
            };
            placed = App.sessionWindowPlacementOn(&host, left_taskbar).?;
            try std.testing.expectEqual(normal.left + 48, placed.rect.?.left);
            try std.testing.expectEqual(normal.top, placed.rect.?.top);
            try std.testing.expectEqual(normal.right - normal.left, placed.rect.?.right - placed.rect.?.left);

            // Minimized from maximized, it comes back maximized, which is
            // what the session has to say. `IsZoomed` alone said normal.
            _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
            try std.testing.expect(sys.IsIconic(hwnd) != 0);
            placed = App.sessionWindowPlacement(&host).?;
            try std.testing.expectEqualDeep(normal, placed.rect.?);
            try std.testing.expect(placed.maximized);

            // Minimized from a normal window, it comes back normal, even
            // though Windows left the restore-to-maximized flag on it.
            _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
            _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
            try std.testing.expect(sys.IsZoomed(hwnd) == 0 and sys.IsIconic(hwnd) == 0);
            _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
            placed = App.sessionWindowPlacement(&host).?;
            try std.testing.expectEqualDeep(normal, placed.rect.?);
            try std.testing.expect(!placed.maximized);
        }
    }.body);
}

test "win32 session placement roundtrips fullscreen and the window it leaves fullscreen to" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;

            const Case = struct {
                maximize: bool = false,
                fullscreen: bool = false,
                /// Maximized by the user before it enters fullscreen.
                zoomed: bool = false,
            };
            // Entered from a normal window and from a maximized one, and
            // started fullscreen by the settings, alone and with `maximize`.
            for ([_]Case{ .{}, .{ .zoomed = true }, .{ .fullscreen = true }, .{ .maximize = true, .fullscreen = true } }) |case| {
                app.config.maximize = case.maximize;
                app.config.fullscreen = if (case.fullscreen) .true else .false;
                try app.createWindow(default_title);
                const surface = fixture.newest();
                const hwnd = surface.windowHwnd().?;
                const host = surface.host.?;
                const created = Fixture.hidden_rect;
                const maximized = case.zoomed or case.maximize;
                if (case.zoomed) _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
                if (!case.fullscreen) try surface.toggleFullscreen(.native);
                try std.testing.expect(surface.fullscreen);
                try std.testing.expectEqualDeep(try Fixture.monitorRect(hwnd), try Fixture.screenRect(hwnd));

                // Not a normal window over the whole monitor, which it was
                // saved as before, and came back as.
                var placed = App.sessionWindowPlacement(host).?;
                try std.testing.expectEqualDeep(created, placed.rect.?);
                try std.testing.expectEqual(maximized, placed.maximized);
                try std.testing.expect(placed.fullscreen);
                // Minimized while fullscreen, the same.
                _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
                placed = App.sessionWindowPlacement(host).?;
                try std.testing.expectEqualDeep(created, placed.rect.?);
                try std.testing.expectEqual(maximized, placed.maximized);
                try std.testing.expect(placed.fullscreen);

                // Exercise the real snapshot, JSON codec and restore path,
                // with fullscreen disabled in config on the next launch.
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const state = try app.buildSessionState(arena.allocator(), 0);
                const encoded = try win32_session_state.encodeAlloc(arena.allocator(), state);
                var parsed = try win32_session_state.parseAlloc(std.testing.allocator, encoded);
                defer parsed.deinit();
                try std.testing.expectEqualStrings("fullscreen", @tagName(parsed.value.windows[0].state.?));
                try std.testing.expectEqual(@as(?bool, maximized), parsed.value.windows[0].fullscreen_maximized);
                fixture.closeWindows();
                app.config.maximize = false;
                app.config.fullscreen = .false;
                // Create at a different size so skipping saved placement
                // cannot accidentally return to the right rectangle.
                Fixture.initial_size = .{ .width = 400, .height = 300 };
                defer Fixture.initial_size = null;
                const restored = try app.restoreSessionWindow(parsed.value.windows[0]);
                try std.testing.expect(!std.meta.eql(created, Fixture.hidden_rect));
                const restored_hwnd = restored.windowHwnd().?;
                try std.testing.expect(restored.fullscreen);
                try std.testing.expectEqualDeep(try Fixture.monitorRect(restored_hwnd), try Fixture.screenRect(restored_hwnd));
                try restored.toggleFullscreen(.native);
                try std.testing.expectEqual(maximized, sys.IsZoomed(restored_hwnd) != 0);
                try std.testing.expectEqualDeep(created, try Fixture.normalRect(restored_hwnd));
                if (maximized) _ = sys.ShowWindow(restored_hwnd, c.SW_RESTORE);
                try std.testing.expectEqualDeep(created, try Fixture.screenRect(restored_hwnd));
                fixture.closeWindows();
            }
        }
    }.body);
}

test "win32 session restore keeps a window on a monitor and brings one back from a missing monitor" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            const surface = try placementTestSurface(&app, 120, 140);
            defer _ = sys.DestroyWindow(surface.hwnd.?);
            const hwnd = surface.hwnd.?;
            var host: Host = .{ .app = &app, .id = 1, .hwnd = hwnd };
            _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
            const works = WorkAreas.collect();
            try std.testing.expect(works.count > 0);
            const work = works.slice()[0];

            // On screen: exactly where it was saved.
            var window: win32_session_state.Window = .{
                .x = work.left + 40,
                .y = work.top + 50,
                .width = 640,
                .height = 480,
                .state = .normal,
                .selected_tab = 0,
                .tabs = &.{},
            };
            try App.applyRestoredWindowPlacement(&host, window);
            var rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(hwnd, &rect) != 0);
            try std.testing.expectEqualDeep(RECT{ .left = work.left + 40, .top = work.top + 50, .right = work.left + 680, .bottom = work.top + 530 }, rect);

            // Saved where no monitor is: on one, at the size it had.
            window.x = 30_000;
            window.y = 30_000;
            try App.applyRestoredWindowPlacement(&host, window);
            try std.testing.expect(sys.GetWindowRect(hwnd, &rect) != 0);
            try std.testing.expect(insideAWorkArea(rect, works.slice()));
            try std.testing.expectEqual(@as(i32, 640), rect.right - rect.left);
            try std.testing.expectEqual(@as(i32, 480), rect.bottom - rect.top);

            // Windows caps what it is given: a left edge to 16 bits, a width to
            // the largest window. This rect spans every monitor as saved, and
            // is off all of them once Windows is done with it.
            window.state = .normal;
            window.x = -2_000_000_000;
            window.y = work.top + 50;
            window.width = 2_100_000_000;
            window.height = 480;
            try App.applyRestoredWindowPlacement(&host, window);
            try std.testing.expect(sys.GetWindowRect(hwnd, &rect) != 0);
            try std.testing.expect(rectEqual(restoredRectOnScreen(rect, works.slice(), restore_grab), rect));
            try std.testing.expect(rect.right - rect.left <= work.right - work.left);

            // The rect a maximized window comes back to is on a monitor too.
            window.x = -30_000;
            window.y = -30_000;
            window.state = .maximized;
            try App.applyRestoredWindowPlacement(&host, window);
            try std.testing.expect(sys.IsZoomed(hwnd) != 0);
            const normal = App.sessionWindowPlacement(&host).?.rect.?;
            try std.testing.expect(insideAWorkArea(normal, works.slice()));
        }

        fn insideAWorkArea(rect: RECT, works: []const RECT) bool {
            for (works) |work| {
                if (rect.left >= work.left and rect.top >= work.top and
                    rect.right <= work.right and rect.bottom <= work.bottom) return true;
            }
            return false;
        }
    }.body);
}

test "win32 a restored window and a launched layout take maximize and fullscreen over their saved state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;
            const works = WorkAreas.collect();
            try std.testing.expect(works.count > 0);
            const work = works.slice()[0];
            const saved: RECT = .{ .left = work.left + 60, .top = work.top + 70, .right = work.left + 760, .bottom = work.top + 570 };

            const nodes = [_]win32_session_state.Node{.{ .pane = .{} }};
            const tab: win32_session_state.Tab = .{ .selected_leaf = 0, .layout = .{ .root = 0, .nodes = &nodes } };
            const Case = struct {
                maximize: bool = false,
                fullscreen: bool = false,
                /// A saved session's window; null is a launched layout's,
                /// whose geometry and state are stripped.
                state: ?win32_session_state.WindowState = null,
                fullscreen_maximized: bool = false,
                /// Launched minimized: the first show is a minimize.
                minimized: bool = false,
                maximized: bool,
            };
            for ([_]Case{
                // Unchanged: a saved normal window comes back normal at its
                // rect, and a saved maximized one maximized (the positive
                // control, which passed before the fix).
                .{ .state = .normal, .maximized = false },
                .{ .state = .maximized, .maximized = true },
                .{ .maximize = true, .state = .maximized, .maximized = true },
                // `maximize` over a saved normal window: its saved rect is
                // the one it un-maximizes to.
                .{ .maximize = true, .state = .normal, .maximized = true },
                .{ .maximize = true, .maximized = true },
                .{ .fullscreen = true, .state = .normal, .maximized = false },
                .{ .maximize = true, .fullscreen = true, .state = .normal, .maximized = true },
                // A minimized launch minimizes the first show, before the
                // window has its saved rect. It still returns to that rect
                // (it came back where it was created before), and a
                // minimized window is not made fullscreen in place (it
                // stayed a minimized popup).
                .{ .minimized = true, .state = .normal, .maximized = false },
                .{ .minimized = true, .state = .maximized, .maximized = true },
                .{ .minimized = true, .maximize = true, .state = .normal, .maximized = true },
                .{ .minimized = true, .fullscreen = true, .state = .normal, .maximized = false },
                .{ .minimized = true, .maximize = true, .fullscreen = true, .state = .normal, .maximized = true },
                .{ .minimized = true, .fullscreen = true, .maximized = false },
                .{ .state = .fullscreen, .maximized = false },
                .{ .state = .fullscreen, .fullscreen_maximized = true, .maximized = true },
                .{ .fullscreen = true, .state = .fullscreen, .fullscreen_maximized = true, .maximized = true },
                .{ .minimized = true, .state = .fullscreen, .maximized = false },
                .{ .minimized = true, .state = .fullscreen, .fullscreen_maximized = true, .maximized = true },
                .{ .maximize = true, .state = .fullscreen, .maximized = true },
            }) |case| {
                app.config.maximize = case.maximize;
                app.config.fullscreen = if (case.fullscreen) .true else .false;
                Fixture.minimize_first_show = case.minimized;
                // Two tabs, the second selected: every tab shares the
                // window's fullscreen.
                const tabs = [_]win32_session_state.Tab{ tab, tab };
                const surface = try app.restoreSessionWindow(.{
                    .x = if (case.state != null) saved.left else null,
                    .y = if (case.state != null) saved.top else null,
                    .width = if (case.state != null) saved.right - saved.left else null,
                    .height = if (case.state != null) saved.bottom - saved.top else null,
                    .state = case.state,
                    .fullscreen_maximized = case.fullscreen_maximized,
                    .selected_tab = 1,
                    .tabs = &tabs,
                });
                const hwnd = surface.windowHwnd().?;
                const host = surface.host.?;
                try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
                try std.testing.expect(host.activeSurface() == surface);
                // A layout has no rect of its own: it keeps where it was
                // created.
                const normal = if (case.state != null) saved else Fixture.hidden_rect;
                if (case.minimized and !case.maximize and !case.fullscreen and case.state == .normal) {
                    // Nothing else un-minimizes it before activation.
                    try std.testing.expect(sys.IsIconic(hwnd) != 0);
                    try std.testing.expectEqualDeep(normal, try Fixture.normalRect(hwnd));
                }
                // As `restoreSessionState` does next.
                app.activateSurface(surface);
                try std.testing.expect(sys.IsIconic(hwnd) == 0);
                for (host.tabs.items) |*each| {
                    try std.testing.expectEqual(case.fullscreen or case.state == .fullscreen, each.focusedSurface().?.fullscreen);
                }
                if (case.fullscreen or case.state == .fullscreen) {
                    // Same-host synchronization must finish even when the
                    // app allocator cannot collect a generic clone list.
                    {
                        const alloc = app.core_app.alloc;
                        app.core_app.alloc = std.testing.failing_allocator;
                        defer app.core_app.alloc = alloc;
                        for (host.tabs.items) |*each| {
                            const other = each.focusedSurface().?;
                            if (other == surface) continue;
                            other.fullscreen = false;
                            other.restore_rect = std.mem.zeroes(RECT);
                        }
                        App.syncRestoredHostWindowState(host, surface);
                        for (host.tabs.items) |*each| {
                            const other = each.focusedSurface().?;
                            try std.testing.expect(other.fullscreen);
                            try std.testing.expectEqualDeep(surface.restore_rect, other.restore_rect);
                            try std.testing.expectEqualDeep(surface.restore_placement, other.restore_placement);
                        }
                    }
                    try std.testing.expectEqualDeep(try Fixture.monitorRect(hwnd), try Fixture.screenRect(hwnd));
                    try std.testing.expect(sys.IsZoomed(hwnd) == 0);
                    try surface.toggleFullscreen(.native);
                    try std.testing.expect(Fixture.framed(hwnd));
                }
                try std.testing.expectEqual(case.maximized, sys.IsZoomed(hwnd) != 0);
                try std.testing.expectEqualDeep(normal, try Fixture.normalRect(hwnd));
                if (!case.maximized) try std.testing.expectEqualDeep(normal, try Fixture.screenRect(hwnd));
                fixture.closeWindows();
            }
        }
    }.body);
}

test "named layout fixture materializes through the session restore split tree builder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const fixture =
        \\{ "schema_version": 1, "windows": [ { "selected_tab": 0, "tabs": [ { "selected_leaf": 1, "layout": { "root": 0, "nodes": [
        \\  { "split": { "axis": "horizontal", "ratio": 0.25, "first": 1, "second": 2 } },
        \\  { "pane": { "cwd": "C:\\\\left", "profile": "pwsh" } },
        \\  { "split": { "axis": "vertical", "ratio": 0.75, "first": 3, "second": 4 } },
        \\  { "pane": { "cwd": "C:\\\\top-right", "title_override": "Top" } },
        \\  { "pane": { "cwd": "C:\\\\bottom-right", "tab_title_override": "Project" } }
        \\] } } ] } ] }
    ;
    var parsed = try win32_session_state.parseAlloc(std.testing.allocator, fixture);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.windows.len);

    var surface_a: Surface = undefined;
    var surface_b: Surface = undefined;
    var surface_c: Surface = undefined;
    const node_surfaces = [_]?*Surface{
        null,
        &surface_a,
        null,
        &surface_b,
        &surface_c,
    };
    var tree = try App.buildRestoredSessionSplitTree(
        std.testing.allocator,
        parsed.value.windows[0].tabs[0].layout,
        &node_surfaces,
    );
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 5), tree.nodes.len);
    try std.testing.expectEqual(SplitTreeSurface.Split.Layout.horizontal, tree.nodes[0].split.layout);
    try std.testing.expectEqual(@as(f16, 0.25), tree.nodes[0].split.ratio);
    try std.testing.expectEqual(&surface_a, tree.nodes[1].leaf);
    try std.testing.expectEqual(SplitTreeSurface.Split.Layout.vertical, tree.nodes[2].split.layout);
    try std.testing.expectEqual(@as(f16, 0.75), tree.nodes[2].split.ratio);
    try std.testing.expectEqual(&surface_b, tree.nodes[3].leaf);
    try std.testing.expectEqual(&surface_c, tree.nodes[4].leaf);
}

test "win32 session restore rebuilds saved split tree shape" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var surface_a: Surface = undefined;
    var surface_b: Surface = undefined;
    var surface_c: Surface = undefined;

    const layout_nodes = [_]win32_session_state.Node{
        .{ .split = .{
            .axis = .horizontal,
            .ratio = 0.25,
            .first = 1,
            .second = 2,
        } },
        .{ .pane = .{ .cwd = "C:\\left" } },
        .{ .split = .{
            .axis = .vertical,
            .ratio = 0.75,
            .first = 3,
            .second = 4,
        } },
        .{ .pane = .{ .cwd = "C:\\top-right" } },
        .{ .pane = .{ .cwd = "C:\\bottom-right" } },
    };
    const node_surfaces = [_]?*Surface{
        null,
        &surface_a,
        null,
        &surface_b,
        &surface_c,
    };

    var tree = try App.buildRestoredSessionSplitTree(
        std.testing.allocator,
        .{ .root = 0, .nodes = &layout_nodes },
        &node_surfaces,
    );
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 5), tree.nodes.len);
    try std.testing.expectEqual(SplitTreeSurface.Split.Layout.horizontal, tree.nodes[0].split.layout);
    try std.testing.expectEqual(@as(f16, 0.25), tree.nodes[0].split.ratio);
    try std.testing.expectEqual(@as(SplitTreeSurface.Node.Handle, @enumFromInt(1)), tree.nodes[0].split.left);
    try std.testing.expectEqual(@as(SplitTreeSurface.Node.Handle, @enumFromInt(2)), tree.nodes[0].split.right);
    try std.testing.expectEqual(&surface_a, tree.nodes[1].leaf);
    try std.testing.expectEqual(SplitTreeSurface.Split.Layout.vertical, tree.nodes[2].split.layout);
    try std.testing.expectEqual(@as(f16, 0.75), tree.nodes[2].split.ratio);
    try std.testing.expectEqual(@as(SplitTreeSurface.Node.Handle, @enumFromInt(3)), tree.nodes[2].split.left);
    try std.testing.expectEqual(@as(SplitTreeSurface.Node.Handle, @enumFromInt(4)), tree.nodes[2].split.right);
    try std.testing.expectEqual(&surface_b, tree.nodes[3].leaf);
    try std.testing.expectEqual(&surface_c, tree.nodes[4].leaf);
}

test "win32 session restore rejects split tree with missing pane surface" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const layout_nodes = [_]win32_session_state.Node{
        .{ .pane = .{ .cwd = "C:\\left" } },
    };
    const node_surfaces = [_]?*Surface{null};

    try std.testing.expectError(
        error.InvalidTreeShape,
        App.buildRestoredSessionSplitTree(
            std.testing.allocator,
            .{ .root = 0, .nodes = &layout_nodes },
            &node_surfaces,
        ),
    );
}
