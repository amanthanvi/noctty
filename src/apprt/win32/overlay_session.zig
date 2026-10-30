//! Overlay and confirmation lifecycle. Host and Surface retain coordination.
const labels = @import("labels.zig");
const win32 = @import("../win32.zig");
const runtime = win32.overlay_session_runtime;
const Allocator = runtime.Allocator;
const HWND = runtime.HWND;
const Host = runtime.Host;
const HostOverlayMode = runtime.HostOverlayMode;
const HostTabStatus = runtime.HostTabStatus;
const LONG_PTR = runtime.LONG_PTR;
const OverlayConfirmPreview = runtime.OverlayConfirmPreview;
const OverlayConfirmText = runtime.OverlayConfirmText;
const OverlayFocusSlot = runtime.OverlayFocusSlot;
const WPARAM = runtime.WPARAM;
const appendOwnedString = runtime.appendOwnedString;
const applyChildVisibility = runtime.applyChildVisibility;
const buildCommandPaletteFeedbackText = runtime.buildCommandPaletteFeedbackText;
const buildCommandPaletteOverlayLabel = runtime.buildCommandPaletteOverlayLabel;
const buildConfirmBodyText = runtime.buildConfirmBodyText;
const buildConfirmPreview = runtime.buildConfirmPreview;
const buildConfirmPreviewCaption = runtime.buildConfirmPreviewCaption;
const buildOverlayAcceptLabel = runtime.buildOverlayAcceptLabel;
const buildOverlayHintText = runtime.buildOverlayHintText;
const buildProfileAcceptLabel = runtime.buildProfileAcceptLabel;
const buildProfileHintText = runtime.buildProfileHintText;
const buildProfileOverlayLabel = runtime.buildProfileOverlayLabel;
const buildTabOverviewOverlayLabel = runtime.buildTabOverviewOverlayLabel;
const c = runtime.c;
const chromeSyncOrLog = runtime.chromeSyncOrLog;
const confirmPromptUiaName = runtime.confirmPromptUiaName;
const destroySubclassedWindow = runtime.destroySubclassedWindow;
const detachChromeControlProvider = runtime.detachChromeControlProvider;
const editSnapshot = runtime.editSnapshot;
const hostButtonProc = runtime.hostButtonProc;
const host_overlay_height = runtime.host_overlay_height;
const lastError = runtime.lastError;
const log = runtime.log;
const nativeEditSelection = runtime.nativeEditSelection;
const nextVisibleOverlayFocusSlot = runtime.nextVisibleOverlayFocusSlot;
const overlayAcceptButtonVisible = runtime.overlayAcceptButtonVisible;
const overlayCancelLabel = runtime.overlayCancelLabel;
const overlayEditProc = runtime.overlayEditProc;
const overlayPromptTextProc = runtime.overlayPromptTextProc;
const overlayTextFollowsActiveSurface = runtime.overlayTextFollowsActiveSurface;
const palette_list_class_name = runtime.palette_list_class_name;
const palette_max_visible_rows = runtime.palette_max_visible_rows;
const palette_row_height = runtime.palette_row_height;
const program_confirm_arming_ms = runtime.program_confirm_arming_ms;
const prompt_button_class = runtime.prompt_button_class;
const prompt_edit_class = runtime.prompt_edit_class;
const prompt_label_class = runtime.prompt_label_class;
const readWindowTextUtf8Alloc = runtime.readWindowTextUtf8Alloc;
const refocusActiveSurface = runtime.refocusActiveSurface;
const runUiActionOrLog = runtime.runUiActionOrLog;
const selectNativeEditRange = runtime.selectNativeEditRange;
const setWindowData = runtime.setWindowData;
const shouldRefocusAfterOverlayHide = runtime.shouldRefocusAfterOverlayHide;
const std = runtime.std;
const syncWindowTextUtf8Cached = runtime.syncWindowTextUtf8Cached;
const syncWindowTextUtf8CachedAfterSet = runtime.syncWindowTextUtf8CachedAfterSet;
const sys = runtime.sys;
const win32_uia = runtime.win32_uia;
const App = test_runtime.App;
const Surface = test_runtime.Surface;
const test_runtime = if (@import("builtin").is_test) win32.overlay_session_test_runtime else struct {};
const CoreApp = test_runtime.CoreApp;
const TestSession = test_runtime.TestSession;
const builtin = test_runtime.builtin;

/// Style for the confirm prompt's title and body STATICs.
///
/// Owner-drawn rather than a plain text STATIC so both renderers of those
/// two lines stay one function: `WM_DRAWITEM` runs the same
/// `gdi.drawTextWz` call with the same `DrawText` flags chrome paint uses
/// for the fallback. A stock STATIC would have to re-derive the vertical
/// position, and `SS_CENTERIMAGE` rounds its half-leading up where
/// `DT_VCENTER` truncates, which measurably moved the body line by a
/// pixel at 150% DPI.
const prompt_text_static_style: u32 = c.SS_OWNERDRAW;

const prompt_ok_label = std.unicode.utf8ToUtf16LeStringLiteral("OK");

const prompt_cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Cancel");

const host_overlay_command_palette_label_utf8 = "Command:";

const host_overlay_profile_label_utf8 = "Profile:";

const host_overlay_surface_title_label_utf8 = "Window title:";

const host_overlay_tab_title_label_utf8 = "Tab title:";

const host_overlay_command_palette_label = std.unicode.utf8ToUtf16LeStringLiteral("Command:");

const confirm_preview_limit = labels.confirm_preview_limit;

/// What a caller is asking the user to approve. A struct rather than
/// positional arguments because every string field has the same type:
/// swapping `title` and `accept_label` used to compile cleanly. Borrows
/// the caller's strings; `showConfirm` copies what it keeps.
pub const ConfirmPrompt = struct {
    title: []const u8,
    body: []const u8,
    accept_label: []const u8,
    cancel_label: []const u8,
    /// The payload this prompt is about, rendered verbatim in the
    /// preview pane. Null for prompts with nothing to show, such as
    /// the close-surface prompt.
    contents: ?[]const u8 = null,
    /// A program in the terminal asked (an OSC 52 clipboard read or
    /// write), not the user. It can send the request right after a key it
    /// read, so the user's next key lands on the prompt: such a prompt
    /// opens on Cancel, ignores Allow for its first
    /// `program_confirm_arming_ms`, and never replaces an open prompt.
    /// A link prompt (`App.askBeforeOpeningLink`) sets it too, but the
    /// user's click raises it, so it replaces an open prompt.
    program_request: bool = false,
};

pub const ConfirmCancelReason = enum { explicit, dismissed };

/// Payload for a non-modal confirm overlay. The callbacks receive the
/// `userdata` pointer passed at construction time so the issuer can
/// bind state (e.g. which Surface's close is pending). Callbacks are
/// invoked exactly once — either `on_accept` or `on_cancel` — and the
/// payload is dropped immediately after. Owned byte slices
/// (`title`, `body`, `accept_label`, `cancel_label`) live on the Host's
/// allocator; `deinit` frees them.
pub const ConfirmPayload = struct {
    title: []u8,
    body: []u8,
    accept_label: []u8,
    cancel_label: []u8,
    /// Display-capped rendering of `ConfirmPrompt.contents`, built once
    /// when the prompt opens. This is for the eyes only — Accept
    /// delivers the Surface's pending clipboard op, never these bytes.
    preview: ?OverlayConfirmPreview = null,
    /// How much is being approved, stated next to the body because the
    /// pane may only show the head of a large payload.
    preview_caption: ?[]u8 = null,
    program_request: bool = false,
    /// `GetTickCount64` before which Allow does nothing; 0 for prompts
    /// the user's own action raised.
    armed_at_ms: u64 = 0,
    on_accept: *const fn (userdata: ?*anyopaque) void,
    on_cancel: ?*const fn (userdata: ?*anyopaque, reason: ConfirmCancelReason) void = null,
    userdata: ?*anyopaque = null,

    pub fn deinit(self: *ConfirmPayload, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
        alloc.free(self.accept_label);
        alloc.free(self.cancel_label);
        if (self.preview) |*preview| preview.deinit(alloc);
        if (self.preview_caption) |caption| alloc.free(caption);
    }
};

fn beginConfirmOverlay(
    host: *Host,
    payload: ConfirmPayload,
    ensure_controls: *const fn (*Host) anyerror!void,
    present: *const fn (*Host) anyerror!void,
) !void {
    // Lazy control creation finishes by resetting the overlay to its hidden
    // baseline. Do that before installing the confirm payload so first-use
    // initialization cannot discard the labels, body, and callbacks.
    try ensure_controls(host);
    host.confirm_payload = payload;
    // The caller frees the payload on failure. `present` may already have
    // put the host in `.confirm` mode, and a host left there declines every
    // program request, so hide what it showed; with the payload taken back
    // first, hideOverlay neither frees it nor runs its cancel.
    errdefer {
        host.confirm_payload = null;
        host.hideOverlay();
    }
    try present(host);
}

pub fn overlayEditText(self: *Host) ![]const u8 {
    const edit_hwnd = self.overlay_edit_hwnd orelse return "";
    if (self.cached_overlay_edit) |value| return value;

    const raw = try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
    defer self.app.core_app.alloc.free(raw);
    try appendOwnedString(self.app.core_app.alloc, &self.cached_overlay_edit, raw);
    return self.cached_overlay_edit orelse "";
}

fn overlayEditNameThunk(ctx: *anyopaque, buf: []u8) []const u8 {
    _ = buf;
    const host: *const Host = @ptrCast(@alignCast(ctx));
    return switch (host.overlay_mode) {
        .command_palette => "Command palette query",
        .profile => "Profile filter",
        .search => "Search query",
        .surface_title => "Surface title",
        .tab_title => "Tab title",
        .tab_overview => "Tab overview filter",
        .none, .confirm => "Overlay input",
    };
}

fn overlayEditValueThunk(ctx: *anyopaque, alloc: Allocator) ![]u8 {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const value = try overlayEditText(host);
    return alloc.dupe(u8, value);
}

fn overlayEditSnapshotThunk(ctx: *anyopaque, alloc: Allocator) !win32_uia.TerminalSnapshot {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const hwnd = host.overlay_edit_hwnd orelse return error.ElementNotAvailable;
    const value = try overlayEditText(host);
    return editSnapshot(alloc, hwnd, value);
}

fn overlayEditFocusedThunk(ctx: *anyopaque) bool {
    const host: *const Host = @ptrCast(@alignCast(ctx));
    const hwnd = host.overlay_edit_hwnd orelse return false;
    return sys.GetFocus() == hwnd;
}

fn overlayEditSetValueThunk(ctx: *anyopaque, value: []const u8) !void {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const hwnd = host.overlay_edit_hwnd orelse return error.ElementNotAvailable;
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(host.app.core_app.alloc, value);
    defer host.app.core_app.alloc.free(value_w);
    if (sys.SetWindowTextW(hwnd, value_w.ptr) == 0) return lastError();
}

fn overlayEditSelectRangeThunk(
    ctx: *anyopaque,
    snapshot_text: []const u8,
    range: win32_uia.OffsetRange,
) !void {
    const host: *Host = @ptrCast(@alignCast(ctx));
    const hwnd = host.overlay_edit_hwnd orelse return error.ElementNotAvailable;
    selectNativeEditRange(hwnd, snapshot_text, range);
}

test "win32 palette EN_CHANGE re-entry guard: suppress_edit_events gates sync cascade" {
    // Sentinel test — the Host struct MUST carry the
    // `suppress_edit_events: bool = false` flag. The palette edit
    // path relies on it gating the EN_CHANGE handler at
    // `hostWindowProc` (command_id 2002) and on `setOverlayEditText`
    // flipping it around programmatic `SetWindowTextW` calls. If a
    // refactor removes or renames the field this test fails
    // at compile time before anyone else hits the crash again.
    try std.testing.expect(@hasField(Host, "suppress_edit_events"));
    try std.testing.expectEqual(bool, @FieldType(Host, "suppress_edit_events"));
}

test "win32 a prompt that replaces another dismisses it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

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

    try surface_a.requestPasteConfirm(.{ .osc_52_read = .standard }, "secret");
    try std.testing.expect(surface_a.pending_clipboard_op != null);

    // The user's own paste in the other tab replaces it: the read's payload
    // is released, not parked until that tab's next request. The user's
    // prompt keeps its wording, opens armed and keeps its payload.
    try surface_b.requestPasteConfirm(.paste, "a\nb");
    try std.testing.expect(surface_a.pending_clipboard_op == null);
    const payload = host.confirm_payload.?;
    try std.testing.expectEqualStrings("Allow clipboard paste?", payload.title);
    try std.testing.expect(!payload.program_request);
    try std.testing.expectEqual(@as(u64, 0), payload.armed_at_ms);
    try std.testing.expectEqualStrings("a\nb", surface_b.pending_clipboard_op.?.paste.data);

    // A tab replacing its own prompt keeps the new request.
    try surface_b.requestPasteConfirm(.paste, "c\nd");
    try std.testing.expectEqualStrings("c\nd", surface_b.pending_clipboard_op.?.paste.data);

    host.invokeConfirmCancel();
    try std.testing.expect(surface_b.pending_clipboard_op == null);

    // Anything else that closes a confirm dismisses it too: the
    // palette, search and rename hide the open overlay first.
    try surface_a.requestPasteConfirm(.{ .osc_52_read = .standard }, "secret");
    host.hideOverlay();
    try std.testing.expect(surface_a.pending_clipboard_op == null);

    // A user prompt has no arming to hold.
    try surface_b.requestPasteConfirm(.paste, "e\nf");
    host.holdProgramConfirm();
    try std.testing.expectEqual(@as(u64, 0), host.confirm_payload.?.armed_at_ms);
    host.invokeConfirmCancel();
    try std.testing.expect(surface_b.pending_clipboard_op == null);

    // A program does not close what the user is typing in either.
    try host.showOverlay(.surface_title, null);
    try std.testing.expectError(error.OverlayOpen, surface_a.requestPasteConfirm(.{ .osc_52_read = .standard }, "secret"));
    try std.testing.expectEqual(HostOverlayMode.surface_title, host.overlay_mode);
    host.hideOverlay();

    // Closing the requester's tab into undo history takes its prompt with
    // it: Allow would answer a terminal that is now only history.
    try surface_b.requestPasteConfirm(.{ .osc_52_read = .standard }, "secret");
    var entry = host.detachTabForUndo(1).?;
    defer entry.dispose(&host, .host_destroy) catch {}; // Best-effort test teardown.
    try std.testing.expectEqual(HostOverlayMode.none, host.overlay_mode);
    try std.testing.expect(surface_b.pending_clipboard_op == null);
    try std.testing.expect(try host.restoreClosedTabEntry(&entry.payload.close_tab));
}

pub const HostControls = struct {
    /// Programmatically set the overlay EDIT's text and keep the
    /// cached UTF-8 view in sync. Wraps the write in
    /// `suppress_edit_events` so the synchronous `EN_CHANGE` that
    /// `SetWindowTextW` fires on the same thread does NOT re-run the
    /// cache-invalidate + sync cascade while the outer caller is
    /// mid-write. Callers must still drive their own
    /// `syncCommandPaletteBanner` / `syncOverlay*` after the write —
    /// the suppressed EN_CHANGE intentionally skips that default
    /// path. See AGENTS.md:75.
    pub fn setOverlayEditText(self: *Host, value: []const u8) !bool {
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        self.suppress_edit_events = true;
        defer self.suppress_edit_events = false;
        const changed = try syncWindowTextUtf8CachedAfterSet(
            self.app.core_app.alloc,
            edit_hwnd,
            &self.cached_overlay_edit,
            value,
        );
        if (changed) {
            if (self.overlay_edit_uia_provider) |provider| {
                provider.raiseTextChanged();
                provider.raiseValueChanged();
            }
            self.raiseOverlayEditSelectionChangedIfNeeded();
        }
        return changed;
    }

    pub fn overlayEditUiaState(self: *const Host) win32_uia.TerminalState {
        return .{
            .ctx = @ptrCast(@constCast(self)),
            .name = &overlayEditNameThunk,
            .value = &overlayEditValueThunk,
            .snapshot = &overlayEditSnapshotThunk,
            .focused = &overlayEditFocusedThunk,
            .role = .edit,
            .use_com_threading = self.app.com_initialized,
            .set_value = &overlayEditSetValueThunk,
            .select_range = &overlayEditSelectRangeThunk,
        };
    }

    pub fn raiseOverlayEditSelectionChangedIfNeeded(self: *Host) void {
        const hwnd = self.overlay_edit_hwnd orelse return;
        const provider = self.overlay_edit_uia_provider orelse return;
        const selection = nativeEditSelection(hwnd);
        if (self.overlay_edit_uia_selection) |previous| {
            if (std.meta.eql(previous, selection)) return;
        }
        self.overlay_edit_uia_selection = selection;
        provider.raiseTextSelectionChanged();
    }

    pub fn setOverlayDefaultBanner(self: *Host, mode: HostOverlayMode) !void {
        _ = mode;
        try self.setBanner(.none, null);
    }

    pub fn ensureOverlayControls(self: *Host) !void {
        const hwnd = self.hwnd orelse return;
        if (self.overlay_edit_hwnd != null) return;

        self.overlay_label_hwnd = sys.CreateWindowExW(
            0,
            prompt_label_class,
            host_overlay_command_palette_label,
            c.WS_CHILD | prompt_text_static_style,
            0,
            0,
            80,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2001),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        self.initOverlayPromptText(
            self.overlay_label_hwnd.?,
            &self.overlay_label_prev_proc,
            &self.overlay_title_uia_provider,
            &confirmTitleUiaName,
        );
        // A later `CreateWindowExW` in this function can still fail. The
        // guard at the top keys off `overlay_edit_hwnd`, so a retry after
        // a partial run would skip straight past this control and
        // overwrite its provider and saved wndproc without detaching
        // them -- leaving a live HWND whose `GWLP_USERDATA` points at a
        // Host that nothing will ever clean up through. Unwind instead.
        errdefer {
            detachChromeControlProvider(self.app, &self.overlay_title_uia_provider);
            destroySubclassedWindow(&self.overlay_label_hwnd, &self.overlay_label_prev_proc);
        }

        self.overlay_edit_hwnd = sys.CreateWindowExW(
            0,
            prompt_edit_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
            0,
            0,
            100,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2002),
            self.app.hinstance,
            null,
        ) orelse return lastError();

        const edit_hwnd = self.overlay_edit_hwnd.?;
        setWindowData(edit_hwnd, self);
        const previous = sys.SetWindowLongPtrW(
            edit_hwnd,
            c.GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(&overlayEditProc))),
        );
        self.overlay_edit_prev_proc = if (previous == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(previous)));
        const edit_margin = @as(u16, @intCast(@max(self.scaled(10), 6)));
        const packed_margins: isize = @intCast(@as(usize, edit_margin) | (@as(usize, edit_margin) << 16));
        _ = sys.SendMessageW(
            edit_hwnd,
            c.EM_SETMARGINS,
            c.EC_LEFTMARGIN | c.EC_RIGHTMARGIN,
            packed_margins,
        );
        self.overlay_edit_uia_provider = if (self.app.com_initialized)
            win32_uia.TerminalProvider.create(
                std.heap.page_allocator,
                edit_hwnd,
                self.overlayEditUiaState(),
            ) catch |err| blk: {
                log.warn("overlay edit UIA provider unavailable err={}", .{err});
                break :blk null;
            }
        else blk: {
            log.debug("overlay edit UIA provider disabled: UI thread is not a confirmed STA", .{});
            break :blk null;
        };

        self.overlay_hint_hwnd = sys.CreateWindowExW(
            0,
            prompt_label_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD | prompt_text_static_style,
            0,
            0,
            100,
            18,
            hwnd,
            @ptrFromInt(2005),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        self.initOverlayPromptText(
            self.overlay_hint_hwnd.?,
            &self.overlay_hint_prev_proc,
            &self.overlay_body_uia_provider,
            &confirmBodyUiaName,
        );
        errdefer {
            detachChromeControlProvider(self.app, &self.overlay_body_uia_provider);
            destroySubclassedWindow(&self.overlay_hint_hwnd, &self.overlay_hint_prev_proc);
        }

        // Confirm preview. Read-only so it cannot be edited, multiline
        // with a vertical scrollbar so a long payload can be inspected,
        // and a tab stop so keyboard users can reach and scroll it.
        // Deliberately NOT `ES_AUTOHSCROLL`: wrapping keeps a long
        // single-line paste visible instead of hiding its tail.
        self.overlay_preview_hwnd = sys.CreateWindowExW(
            0,
            prompt_edit_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD | c.WS_TABSTOP | c.WS_BORDER | c.WS_VSCROLL |
                c.ES_MULTILINE | c.ES_READONLY | c.ES_AUTOVSCROLL,
            0,
            0,
            320,
            120,
            hwnd,
            @ptrFromInt(2007),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        const preview_hwnd = self.overlay_preview_hwnd.?;
        setWindowData(preview_hwnd, self);
        // Share `overlayEditProc`. Both controls are the same EDIT
        // class, so the saved original proc is the same function, and
        // the pane needs the same Tab / Esc / Enter handling: without
        // it, clicking the pane to scroll would strand focus in a
        // control that swallows Tab and ignores Esc.
        const preview_previous = sys.SetWindowLongPtrW(
            preview_hwnd,
            c.GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(&overlayEditProc))),
        );
        self.overlay_preview_prev_proc = if (preview_previous == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(preview_previous)));
        if (self.preview_font) |font| {
            _ = sys.SendMessageW(preview_hwnd, c.WM_SETFONT, @intFromPtr(font), 1);
        }
        if (self.app.com_initialized) {
            if (win32_uia.SettingsControlProvider.create(
                std.heap.page_allocator,
                preview_hwnd,
                .edit,
                "Preview",
            )) |provider| {
                if (self.overlay_title_uia_provider) |title| provider.setLabeledBy(&title.base);
                self.overlay_preview_uia_provider = provider;
            } else |err| {
                log.warn("overlay preview UIA provider unavailable err={}", .{err});
            }
        }

        self.overlay_accept_hwnd = sys.CreateWindowExW(
            0,
            prompt_button_class,
            prompt_ok_label,
            c.WS_CHILD | c.WS_TABSTOP | c.BS_OWNERDRAW,
            0,
            0,
            70,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2003),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        self.subclassButton(self.overlay_accept_hwnd.?, &hostButtonProc, &self.overlay_button_prev_proc);

        self.overlay_cancel_hwnd = sys.CreateWindowExW(
            0,
            prompt_button_class,
            prompt_cancel_label,
            c.WS_CHILD | c.WS_TABSTOP | c.BS_OWNERDRAW,
            0,
            0,
            80,
            host_overlay_height - 8,
            hwnd,
            @ptrFromInt(2004),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        self.subclassButton(self.overlay_cancel_hwnd.?, &hostButtonProc, &self.overlay_button_prev_proc);

        if (self.app.com_initialized) {
            self.overlay_accept_uia_provider = win32_uia.SettingsControlProvider.create(
                std.heap.page_allocator,
                self.overlay_accept_hwnd.?,
                .button,
                null,
            ) catch |err| blk: {
                log.warn("overlay accept UIA provider unavailable err={}", .{err});
                break :blk null;
            };
            self.overlay_cancel_uia_provider = win32_uia.SettingsControlProvider.create(
                std.heap.page_allocator,
                self.overlay_cancel_hwnd.?,
                .button,
                null,
            ) catch |err| blk: {
                log.warn("overlay cancel UIA provider unavailable err={}", .{err});
                break :blk null;
            };
        } else {
            log.warn("overlay button UIA providers disabled: UI thread is not a confirmed STA", .{});
        }

        // Palette list — shown only when overlay_mode == .command_palette.
        // Stamped with a pointer to the Host via GWLP_USERDATA so the
        // wndproc can dispatch clicks back to `host.invokePaletteRow`.
        self.palette_list_hwnd = sys.CreateWindowExW(
            0,
            palette_list_class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD,
            0,
            0,
            320,
            palette_row_height * @as(i32, palette_max_visible_rows),
            hwnd,
            @ptrFromInt(2006),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        setWindowData(self.palette_list_hwnd.?, self);
        self.palette_list_uia_provider = if (self.app.com_initialized)
            win32_uia.PaletteListProvider.create(
                std.heap.page_allocator,
                self.palette_list_hwnd.?,
                self.paletteListUiaState(),
            ) catch |err| blk: {
                log.warn("palette UIA provider unavailable err={}", .{err});
                break :blk null;
            }
        else blk: {
            log.debug("palette UIA provider disabled: UI thread is not a confirmed STA", .{});
            break :blk null;
        };

        self.hideOverlay();
    }

    /// UIA name for the confirm title. Reports the text the control was
    /// actually given rather than re-deriving it, so the spoken name and
    /// the drawn line can never disagree. Empty outside `.confirm`: the
    /// control is hidden there and still holds the previous overlay's
    /// label, which is not a name any client should read.
    fn confirmTitleUiaName(ctx: *anyopaque, _: usize, buf: []u8) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return confirmPromptUiaName(self.overlay_mode, self.cached_overlay_label, buf, "Confirm");
    }

    fn confirmBodyUiaName(ctx: *anyopaque, _: usize, buf: []u8) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return confirmPromptUiaName(self.overlay_mode, self.cached_overlay_hint, buf, "");
    }

    /// Announce a freshly opened confirm prompt. Runs after the text
    /// syncs and after `layout` has shown the controls: a provider whose
    /// HWND is still hidden reports `IsOffscreen`, and a live-region
    /// event on an offscreen element is dropped by readers.
    pub fn announceConfirmPrompt(self: *Host) void {
        if (self.overlay_mode != .confirm) return;
        // Title first: it is what the prompt is asking, and the body only
        // qualifies it. Each is raised only if its child is on screen --
        // a hidden HWND reports `IsOffscreen`, and readers drop live
        // regions that are, so raising there would be noise that hides
        // the fact that the line has no element at all.
        if (self.confirmTitleTextPlaced()) {
            if (self.overlay_title_uia_provider) |provider| provider.raiseLiveRegionChanged();
        }
        if (self.confirmBodyTextPlaced()) {
            if (self.overlay_body_uia_provider) |provider| provider.raiseLiveRegionChanged();
        }
    }

    /// Finish a confirm-prompt text STATIC: chrome font, host back-
    /// pointer, `WM_GETOBJECT` subclass and its UIA provider.
    ///
    /// The font matters now that these controls are drawn. `Host.init`
    /// builds `chrome_font` once and only `recreateChromeFont` re-sends
    /// `WM_SETFONT`, which fires on a DPI or theme change -- not on the
    /// lazy creation path that runs the first time an overlay opens. A
    /// control created here and never sent the font would render in the
    /// stock `SYSTEM_FONT` bitmap face until the user happened to move
    /// the window to another monitor.
    ///
    /// Both prompt lines are `live_text`. The suggestion on the issue
    /// was a plain text role for the title, but focus lands on the
    /// accept button when a confirm opens, and a non-live Text element
    /// nothing is focused on is never spoken -- which is the exact gap
    /// this exists to close. A polite live region is also honest: the
    /// title is a region whose content changes per prompt.
    pub fn initOverlayPromptText(
        self: *Host,
        hwnd: HWND,
        prev_proc: *?*const anyopaque,
        provider_slot: *?*win32_uia.ChromeControlProvider,
        name: *const fn (*anyopaque, usize, []u8) []const u8,
    ) void {
        if (self.chrome_font) |font| {
            _ = sys.SendMessageW(hwnd, c.WM_SETFONT, @intFromPtr(font), 1);
        }
        setWindowData(hwnd, self);
        const previous = sys.SetWindowLongPtrW(
            hwnd,
            c.GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(&overlayPromptTextProc))),
        );
        prev_proc.* = if (previous == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(previous)));
        provider_slot.* = self.createChromeUiaProvider(hwnd, .{
            .ctx = @ptrCast(self),
            .role = .live_text,
            .name = name,
        });
    }

    /// Provider for one of the two confirm prompt text STATICs.
    pub fn overlayPromptTextProvider(
        self: *Host,
        child: HWND,
    ) ?*win32_uia.ChromeControlProvider {
        if (self.overlay_label_hwnd) |label| {
            if (label == child) return self.overlay_title_uia_provider;
        }
        if (self.overlay_hint_hwnd) |hint| {
            if (hint == child) return self.overlay_body_uia_provider;
        }
        return null;
    }

    pub fn overlayPromptTextPrevProc(self: *Host, child: HWND) ?*const anyopaque {
        if (self.overlay_label_hwnd) |label| {
            if (label == child) return self.overlay_label_prev_proc;
        }
        if (self.overlay_hint_hwnd) |hint| {
            if (hint == child) return self.overlay_hint_prev_proc;
        }
        return null;
    }

    pub fn showOverlay(self: *Host, mode: HostOverlayMode, initial: ?[]const u8) !void {
        if (mode == .command_palette) {
            // Theme previews replace the app-global config while palette
            // catalogs borrow config strings. Keep exactly one palette live
            // across all host windows so closing the prior palette reverts its
            // preview and releases its catalog before this host builds one.
            for (self.app.registry.hosts.items) |other| {
                if (other != self and other.overlay_mode == .command_palette) {
                    other.hideOverlay();
                }
            }
        }
        try self.ensureOverlayControls();
        self.overlay_mode = mode;
        self.overlay_edit_uia_selection = null;
        if (self.overlay_edit_uia_provider) |provider| {
            win32_uia.events.raiseNameChanged(&provider.base);
        }
        self.clearOverlayCompletion();
        try self.setOverlayDefaultBanner(mode);

        // Visibility of the title / body STATICs belongs to `layout`:
        // they are shown for `.confirm` and hidden for every other mode.
        // Force-hiding them here would make a confirm open flash them
        // off and straight back on.
        const edit_hwnd = self.overlay_edit_hwnd orelse return;
        if (self.overlay_preview_hwnd) |preview_hwnd| {
            _ = applyChildVisibility(preview_hwnd, &self.overlay_preview_placement, false);
        }
        const accept_hwnd = self.overlay_accept_hwnd orelse return;
        const cancel_hwnd = self.overlay_cancel_hwnd orelse return;

        // Confirm overlays are message-only: they carry the payload's
        // body as read-only explanatory text (the hint HWND) rather
        // than an editable query. Hiding the EDIT removes the blank-
        // textbox-UX-trap and puts keyboard focus on the Accept
        // button by default (Enter = accept, Esc = cancel per the
        // overlayEditProc key handlers; we still capture keys there
        // so focus on the button is just the initial landing spot).
        const is_confirm = mode == .confirm;
        const show_accept = overlayAcceptButtonVisible(mode);
        _ = applyChildVisibility(edit_hwnd, &self.overlay_edit_placement, !is_confirm);
        _ = applyChildVisibility(accept_hwnd, &self.overlay_accept_placement, show_accept);
        _ = applyChildVisibility(cancel_hwnd, &self.overlay_cancel_placement, true);
        self.invalidateOverlayTransitionPlacementCache();

        const initial_text = initial orelse "";
        _ = try self.setOverlayEditText(initial_text);
        self.overlay_text_surface = if (overlayTextFollowsActiveSurface(mode)) self.activeSurface() else null;

        // Keep the syncs: their return values still drive `refreshChrome`,
        // and the control text they write is what the confirm prompt's
        // hint HWND shows. Do NOT gate the invalidation on them here.
        // A sync only reports a change against the control text it wrote
        // last, and other sites (`stepTabOverviewSelection` and the plain
        // `EN_CHANGE` arm) run the same
        // syncs and drop the result, so the control text can already
        // have advanced past what the paint cache holds. The next open
        // would then see "unchanged", skip the invalidate, and paint the
        // PREVIOUS overlay's cached strings — `hideOverlay` never frees
        // those, and the forced transition paint below is synchronous
        // and clears `chrome_repaint_dirty`, so the stale text persists
        // rather than merely flickering.
        _ = try self.syncOverlayLabel();
        _ = try self.syncOverlayHint();
        _ = try self.syncOverlayPreview();
        _ = try self.syncOverlayButtons();
        // The command palette gets a scrollable list below the EDIT;
        // rebuild it for the initial (usually empty) query so the
        // ranker's "show all" path has something visible to draw.
        if (mode == .command_palette) self.rebuildPaletteList();
        // Unconditional, and after `rebuildPaletteList`: opening an
        // overlay is once per gesture, so the cost is one repaint, and
        // the rebuild mutates the palette state the painted label reads.
        self.invalidateOverlayText();
        try self.layout();
        if (is_confirm) {
            // Show body as hint label. Prefer the visible Accept button,
            // then the visible Cancel button, as the keyboard-focus target.
            // The destructive action remains one explicit click/Enter away.
            // A program's prompt prefers Cancel: the key the user was
            // typing when it opened then declines it.
            const program = if (self.confirm_payload) |payload| payload.program_request else false;
            const first = if (program) cancel_hwnd else accept_hwnd;
            const second = if (program) accept_hwnd else cancel_hwnd;
            const initial_target = if (sys.IsWindowVisible(first) != 0)
                first
            else if (sys.IsWindowVisible(second) != 0)
                second
            else {
                self.announceConfirmPrompt();
                return;
            };
            _ = sys.SetFocus(initial_target);
            // After the focus move, so a reader queues the prompt text
            // behind "Allow, button" rather than having it cut off.
            self.announceConfirmPrompt();
        } else {
            _ = sys.SetFocus(edit_hwnd);
            _ = sys.SendMessageW(edit_hwnd, c.EM_SETSEL, 0, -1);
        }
        self.forceOverlayTransitionPaint();
    }

    pub fn hideOverlay(self: *Host) void {
        const was_confirm = self.overlay_mode == .confirm;
        const was_palette = self.overlay_mode == .command_palette;
        const restore_terminal_focus = shouldRefocusAfterOverlayHide(
            sys.GetFocus(),
            self.overlay_edit_hwnd,
            self.overlay_accept_hwnd,
            self.overlay_cancel_hwnd,
            self.palette_list_hwnd,
        );
        self.revertPaletteThemePreview();
        self.overlay_mode = .none;
        self.overlay_text_surface = null;
        self.clearOverlayCompletion();
        runUiActionOrLog("overlay banner clear failed", self.setBanner(.none, null));
        // Drop any active confirm payload. Both accept and cancel
        // paths route through hideOverlay, so this is the one place
        // the owned byte slices get freed. Accept/cancel callbacks
        // snapshot their callback data before reaching this point and
        // dispatch only after hideOverlay returns.
        //
        // Displacement still releases the pending operation, but is not
        // the user's explicit Cancel. Allow, explicit Cancel and owner
        // teardown clear `on_cancel` first. The callers of hideOverlay
        // go on using Host, so dismissal callbacks must not destroy it.
        const dropped_cancel = if (self.confirm_payload) |p| p.on_cancel else null;
        const dropped_userdata = if (self.confirm_payload) |p| p.userdata else null;
        if (self.confirm_payload) |*p| {
            p.deinit(self.app.core_app.alloc);
            self.confirm_payload = null;
        }
        // Clear the preview pane now rather than on the next overlay
        // open. A hidden EDIT still answers WM_GETTEXT, and a denied
        // clipboard write was never placed on the clipboard, so its
        // bytes must not stay readable from the control after the
        // prompt is gone. Mode is already `.none`, so this writes "".
        _ = chromeSyncOrLog("overlay preview clear failed", self.syncOverlayPreview());
        if (self.overlay_label_hwnd) |hwnd| _ = applyChildVisibility(hwnd, &self.overlay_label_placement, false);
        if (self.overlay_edit_hwnd) |hwnd| _ = applyChildVisibility(hwnd, &self.overlay_edit_placement, false);
        if (self.overlay_hint_hwnd) |hwnd| _ = applyChildVisibility(hwnd, &self.overlay_hint_placement, false);
        if (self.overlay_preview_hwnd) |hwnd| _ = applyChildVisibility(hwnd, &self.overlay_preview_placement, false);
        if (self.overlay_accept_hwnd) |hwnd| _ = applyChildVisibility(hwnd, &self.overlay_accept_placement, false);
        if (self.overlay_cancel_hwnd) |hwnd| _ = applyChildVisibility(hwnd, &self.overlay_cancel_placement, false);
        if (self.palette_list_hwnd) |hwnd| _ = applyChildVisibility(hwnd, &self.palette_list_placement, false);
        self.palette_list_ranked_count = 0;
        self.palette_list_visible_rows = 0;
        self.palette_list_scroll = 0;
        self.palette_wheel_steps = .{};
        if (self.palette_catalog) |*catalog| catalog.reset();
        self.resetPaletteCatalogConfigOwner();
        self.clearPaletteInstalledThemes();
        self.clearPaletteLayoutNames();
        self.invalidateOverlayTransitionPlacementCache();
        self.forceHostCompositionPaint();
        if (was_confirm or was_palette) {
            runUiActionOrLog("overlay hide layout failed", self.layout());
            self.forceVisibleSurfaceRepaintsNow();
        }
        if (restore_terminal_focus) {
            refocusActiveSurface(self);
        }
        // `setBanner(.none, null)` above does nothing when only the update
        // notice is up, and not every caller relayouts after this.
        self.syncBannerChild();
        if (dropped_cancel) |cancel| cancel(dropped_userdata, .dismissed);
    }

    /// Bring up a non-modal confirmation prompt. Ownership of the
    /// four string slices (`title`, `body`, `accept_label`,
    /// `cancel_label`) transfers to the Host — the Host frees them
    /// when the overlay closes. Opening a confirm while another
    /// overlay is active closes the previous one first (policy:
    /// confirm is mutually exclusive with palette / search /
    /// profile).
    pub fn showConfirm(
        self: *Host,
        prompt: ConfirmPrompt,
        on_accept: *const fn (userdata: ?*anyopaque) void,
        on_cancel: ?*const fn (userdata: ?*anyopaque, reason: ConfirmCancelReason) void,
        userdata: ?*anyopaque,
    ) !void {
        const alloc = self.app.core_app.alloc;
        // Deep-copy every string so the caller doesn't need to keep
        // the source alive.
        const title_owned = try alloc.dupe(u8, prompt.title);
        errdefer alloc.free(title_owned);
        const body_owned = try alloc.dupe(u8, prompt.body);
        errdefer alloc.free(body_owned);
        const accept_owned = try alloc.dupe(u8, prompt.accept_label);
        errdefer alloc.free(accept_owned);
        const cancel_owned = try alloc.dupe(u8, prompt.cancel_label);
        errdefer alloc.free(cancel_owned);

        // Render the preview once, here, so a megabyte paste costs one
        // capped copy rather than a rebuild on every chrome repaint.
        var preview: ?OverlayConfirmPreview = null;
        errdefer if (preview) |*value| value.deinit(alloc);
        var caption: ?[]u8 = null;
        errdefer if (caption) |value| alloc.free(value);
        if (prompt.contents) |contents| {
            preview = try buildConfirmPreview(alloc, contents, confirm_preview_limit);
            caption = try buildConfirmPreviewCaption(alloc, preview.?);
        }

        // Close any previous overlay so we don't stack. `hideOverlay`
        // frees an existing `confirm_payload` via its own deinit
        // branch, so we don't leak here, and dismisses it. That
        // cannot undo the new request when it comes from the same
        // Surface: a requester commits its pending op only after this
        // returns.
        if (self.overlay_mode != .none) self.hideOverlay();

        try beginConfirmOverlay(self, .{
            .title = title_owned,
            .body = body_owned,
            .accept_label = accept_owned,
            .cancel_label = cancel_owned,
            .preview = preview,
            .preview_caption = caption,
            .program_request = prompt.program_request,
            .armed_at_ms = if (prompt.program_request) sys.GetTickCount64() + program_confirm_arming_ms else 0,
            .on_accept = on_accept,
            .on_cancel = on_cancel,
            .userdata = userdata,
        }, &Host.ensureOverlayControls, &Host.showConfirmOverlay);
    }

    pub fn showConfirmOverlay(self: *Host) !void {
        try self.showOverlay(.confirm, null);
    }

    /// Fire the accept callback and close the overlay. Critical
    /// ordering: hide the overlay + free the payload FIRST, then
    /// dispatch the callback. The accept handler can synchronously
    /// destroy this Host (e.g. the confirm-close-surface path calls
    /// `DestroyWindow` which triggers the Host's `WM_DESTROY` +
    /// teardown) — touching `self` after that is a use-after-free.
    /// Snapshot the callback into locals, null out the payload,
    /// hide the overlay state, THEN call the callback.
    pub fn invokeConfirmAccept(self: *Host) void {
        const captured = self.confirm_payload orelse {
            self.hideOverlay();
            return;
        };
        // Every way to press Allow ends here (keys, a click, UIA Invoke,
        // Enter in the preview pane), so this is where a program's prompt
        // stays unarmed. A press too early is itself a key or click on
        // the prompt, so it pushes the arming back (`holdProgramConfirm`).
        if (sys.GetTickCount64() < captured.armed_at_ms) {
            self.holdProgramConfirm();
            return;
        }
        const cb = captured.on_accept;
        const userdata = captured.userdata;
        // Allow answers it: hideOverlay must not also run its cancel.
        self.confirm_payload.?.on_cancel = null;
        // hideOverlay deinits the payload (frees the owned byte
        // slices) and clears `confirm_payload = null`. After this
        // point, do not touch Host state before the callback: confirm
        // teardown repaint/focus restoration happens inside
        // hideOverlay while the Host is still owned by this path.
        self.hideOverlay();
        cb(userdata);
    }

    /// Explicit Cancel/Escape. Consume the callback before hiding, just
    /// like Allow, and dispatch only once the overlay is down.
    pub fn invokeConfirmCancel(self: *Host) void {
        const captured = self.confirm_payload orelse {
            self.hideOverlay();
            return;
        };
        const cb = captured.on_cancel;
        const userdata = captured.userdata;
        self.confirm_payload.?.on_cancel = null;
        self.hideOverlay();
        if (cb) |cancel| cancel(userdata, .explicit);
    }

    /// Any key a program's prompt receives starts its arming over, so
    /// Allow takes a key after `program_confirm_arming_ms` of quiet: the
    /// prompt opens on Cancel, but the Tab, Left or Enter of someone still
    /// typing can move focus to Allow or the preview pane, and a fresh
    /// Enter there would otherwise accept once the first half second had
    /// passed. Prompts the user raised are not armed.
    pub fn holdProgramConfirm(self: *Host) void {
        const payload = if (self.confirm_payload) |*p| p else return;
        if (payload.program_request) payload.armed_at_ms = sys.GetTickCount64() + program_confirm_arming_ms;
    }

    /// `holdProgramConfirm` for a key, except a modifier: a held Shift or
    /// Ctrl repeats its keydown, which kept a Shift+click on Allow from
    /// ever landing, and the keys typed with a modifier hold it anyway.
    pub fn holdProgramConfirmForKey(self: *Host, vk: WPARAM) void {
        switch (vk) {
            c.VK_SHIFT, c.VK_CONTROL, c.VK_MENU, c.VK_LWIN, c.VK_RWIN => {},
            else => self.holdProgramConfirm(),
        }
    }

    pub fn programConfirmOpen(self: *const Host) bool {
        const payload = self.confirm_payload orelse return false;
        return payload.program_request;
    }

    /// If an active confirm overlay was opened with `ud` as its
    /// userdata, hide + deinit it WITHOUT dispatching the cancel
    /// callback. Called from `Surface.destroy` so a close-while-
    /// confirming doesn't leave the overlay with a dangling Surface
    /// pointer — a later Accept click would otherwise UAF into the
    /// freed surface. Skipping the cancel callback is correct here:
    /// the Surface is already tearing down, nothing to roll back.
    pub fn cancelConfirmIfOwnedBy(self: *Host, ud: *anyopaque) void {
        const payload = self.confirm_payload orelse return;
        const payload_ud = payload.userdata orelse return;
        if (payload_ud != ud) return;
        // `hideOverlay` deinits the payload (frees owned string
        // bytes and clears `confirm_payload = null`), and with
        // `on_cancel` cleared it invokes neither callback.
        // layout/repaint/refocus are handled inside hideOverlay for
        // the confirm case.
        self.confirm_payload.?.on_cancel = null;
        self.hideOverlay();
    }

    pub fn syncOverlayLabel(self: *Host) !bool {
        const label_hwnd = self.overlay_label_hwnd orelse return false;
        const alloc = self.app.core_app.alloc;
        switch (self.overlay_mode) {
            .none => return try syncWindowTextUtf8Cached(
                alloc,
                label_hwnd,
                &self.cached_overlay_label,
                host_overlay_command_palette_label_utf8,
            ),
            .profile => {
                if (!self.profilesForChrome()) {
                    return try syncWindowTextUtf8Cached(
                        alloc,
                        label_hwnd,
                        &self.cached_overlay_label,
                        host_overlay_profile_label_utf8,
                    );
                }
                const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");
                const label = try buildProfileOverlayLabel(
                    alloc,
                    self.shownProfiles().?,
                    text,
                    self.selectedProfileIndex() orelse 0,
                );
                defer alloc.free(label);
                return try syncWindowTextUtf8Cached(
                    alloc,
                    label_hwnd,
                    &self.cached_overlay_label,
                    label,
                );
            },
            .surface_title => return try syncWindowTextUtf8Cached(
                alloc,
                label_hwnd,
                &self.cached_overlay_label,
                host_overlay_surface_title_label_utf8,
            ),
            .tab_title => return try syncWindowTextUtf8Cached(
                alloc,
                label_hwnd,
                &self.cached_overlay_label,
                host_overlay_tab_title_label_utf8,
            ),
            .command_palette => {
                const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");
                const label = try buildCommandPaletteOverlayLabel(
                    alloc,
                    text,
                    self.palettePresentation(),
                );
                defer alloc.free(label);
                return try syncWindowTextUtf8Cached(
                    alloc,
                    label_hwnd,
                    &self.cached_overlay_label,
                    label,
                );
            },
            .search => return false,
            .tab_overview => {
                const surface = self.activeSurface();
                const status = if (surface) |value| self.app.hostTabStatus(value) else HostTabStatus{};
                const label = try buildTabOverviewOverlayLabel(alloc, status.index, status.total);
                defer alloc.free(label);
                return try syncWindowTextUtf8Cached(
                    alloc,
                    label_hwnd,
                    &self.cached_overlay_label,
                    label,
                );
            },
            .confirm => {
                // Confirm overlays use the payload's title as the
                // label text. Falls back to a sensible default if
                // payload is missing (shouldn't happen; showConfirm
                // guarantees it).
                const title = if (self.confirm_payload) |p|
                    p.title
                else
                    "Confirm";
                return try syncWindowTextUtf8Cached(
                    alloc,
                    label_hwnd,
                    &self.cached_overlay_label,
                    title,
                );
            },
        }
    }

    pub fn syncOverlayButtons(self: *Host) !bool {
        const accept_hwnd = self.overlay_accept_hwnd orelse return false;
        const cancel_hwnd = self.overlay_cancel_hwnd orelse return false;
        const alloc = self.app.core_app.alloc;
        var changed = false;
        // Confirm overlays pull labels from the payload directly so
        // users get the exact wording the caller chose (e.g. "Close"
        // as a destructive Accept). Skip the generic EDIT-text-driven
        // label computation below since there is no EDIT input.
        if (self.overlay_mode == .confirm) {
            if (self.confirm_payload) |p| {
                changed = (try syncWindowTextUtf8Cached(
                    alloc,
                    accept_hwnd,
                    &self.cached_overlay_accept,
                    p.accept_label,
                )) or changed;
                changed = (try syncWindowTextUtf8Cached(
                    alloc,
                    cancel_hwnd,
                    &self.cached_overlay_cancel,
                    p.cancel_label,
                )) or changed;
            }
            return changed;
        }
        const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");
        const surface = self.activeSurface();
        if (self.overlay_mode == .profile) {
            const accept = try buildProfileAcceptLabel(
                alloc,
                self.shownProfiles(),
                text,
                self.selectedProfileIndex() orelse 0,
                self.app.launcher_profile_target,
            );
            defer alloc.free(accept);
            changed = (try syncWindowTextUtf8Cached(
                alloc,
                accept_hwnd,
                &self.cached_overlay_accept,
                accept,
            )) or changed;
            changed = (try syncWindowTextUtf8Cached(
                alloc,
                cancel_hwnd,
                &self.cached_overlay_cancel,
                overlayCancelLabel(self.overlay_mode),
            )) or changed;
            return changed;
        }
        const accept = try buildOverlayAcceptLabel(
            alloc,
            self.overlay_mode,
            text,
            if (surface) |value| value.search_needle else null,
            if (surface) |value| value.search_total else null,
            if (surface) |value| value.search_selected else null,
            self.palettePresentation(),
        );
        defer alloc.free(accept);
        changed = (try syncWindowTextUtf8Cached(
            alloc,
            accept_hwnd,
            &self.cached_overlay_accept,
            accept,
        )) or changed;
        changed = (try syncWindowTextUtf8Cached(
            alloc,
            cancel_hwnd,
            &self.cached_overlay_cancel,
            overlayCancelLabel(self.overlay_mode),
        )) or changed;
        return changed;
    }

    /// Prompt text of the active confirm overlay, for the chrome paint
    /// path. Null while no payload is installed, which makes the label
    /// builders fall back to their placeholders.
    pub fn confirmText(self: *const Host) ?OverlayConfirmText {
        const payload = self.confirm_payload orelse return null;
        return .{
            .title = payload.title,
            .body = payload.body,
            .preview_caption = payload.preview_caption orelse "",
        };
    }

    /// True when the active confirm prompt has something to show in the
    /// preview pane. The close-surface prompt does not: it is about a
    /// running process, not a payload.
    pub fn confirmHasPreview(self: *const Host) bool {
        if (self.overlay_mode != .confirm) return false;
        const payload = self.confirm_payload orelse return false;
        const preview = payload.preview orelse return false;
        return preview.text.len > 0;
    }

    /// Push the confirm payload's rendered preview into the preview
    /// EDIT. Visibility and geometry belong to `layout`, following the
    /// palette list, so the control is never shown at its creation rect
    /// before the first layout pass places it.
    pub fn syncOverlayPreview(self: *Host) !bool {
        const preview_hwnd = self.overlay_preview_hwnd orelse return false;
        const alloc = self.app.core_app.alloc;
        const text: []const u8 = text: {
            if (self.overlay_mode != .confirm) break :text "";
            const payload = self.confirm_payload orelse break :text "";
            const preview = payload.preview orelse break :text "";
            break :text preview.text;
        };
        return try syncWindowTextUtf8Cached(
            alloc,
            preview_hwnd,
            &self.cached_overlay_preview,
            text,
        );
    }

    pub fn syncOverlayHint(self: *Host) !bool {
        const hint_hwnd = self.overlay_hint_hwnd orelse return false;
        const alloc = self.app.core_app.alloc;
        // Confirm overlays show this control: `layout` gives it the rect
        // chrome paint used for the body line. It carries the same string
        // that paint would have drawn -- payload body, preview caption,
        // and a banner override when one is live -- because the UIA name
        // is read straight back off the control, so anything this writes
        // is also what a screen reader says.
        //
        // Visibility still belongs to `layout`, never to this function:
        // the control must not appear at its 100x18 creation rect at
        // client (0,0) before the first layout pass places it.
        if (self.overlay_mode == .confirm) {
            const body = try buildConfirmBodyText(
                alloc,
                self.banner_kind,
                self.banner_text,
                self.confirmText(),
            );
            defer alloc.free(body);
            return try syncWindowTextUtf8Cached(
                alloc,
                hint_hwnd,
                &self.cached_overlay_hint,
                body,
            );
        }
        const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");
        if (self.overlay_mode == .command_palette) {
            var mru_buf: [5][]const u8 = undefined;
            const hint = try buildCommandPaletteFeedbackText(
                alloc,
                text,
                self.app.paletteMruSlice(&mru_buf),
                self.palettePresentation(),
            );
            defer alloc.free(hint);
            return try syncWindowTextUtf8Cached(
                alloc,
                hint_hwnd,
                &self.cached_overlay_hint,
                hint,
            );
        }
        if (self.overlay_mode == .profile) {
            if (self.profiles == null and self.profiles_requested) {
                return try syncWindowTextUtf8Cached(
                    alloc,
                    hint_hwnd,
                    &self.cached_overlay_hint,
                    "Detecting Windows profiles...",
                );
            }
            const hint = try buildProfileHintText(
                alloc,
                self.shownProfiles(),
                text,
                self.selectedProfileIndex() orelse 0,
                self.app.launcher_profile_target,
                self.app.launcher_quick_slot_keys,
            );
            defer alloc.free(hint);
            return try syncWindowTextUtf8Cached(
                alloc,
                hint_hwnd,
                &self.cached_overlay_hint,
                hint,
            );
        }
        const surface = self.activeSurface();
        var mru_buf: [5][]const u8 = undefined;
        const mru = self.app.paletteMruSlice(&mru_buf);
        const hint = try buildOverlayHintText(
            alloc,
            self.overlay_mode,
            text,
            if (surface) |value| value.search_needle else null,
            if (surface) |value| value.search_total else null,
            if (surface) |value| value.search_selected else null,
            if (surface) |value| self.app.hostTabStatus(value) else .{},
            if (self.activeTab()) |tab| tab.leafCount() else 1,
            self.paletteSnapshot(),
            mru,
            // Unreachable for `.confirm`: that mode returns above.
            null,
        );
        defer alloc.free(hint);
        return try syncWindowTextUtf8Cached(
            alloc,
            hint_hwnd,
            &self.cached_overlay_hint,
            hint,
        );
    }

    pub fn isOverlayButton(self: *const Host, child: HWND) bool {
        return (self.overlay_accept_hwnd != null and child == self.overlay_accept_hwnd.?) or
            (self.overlay_cancel_hwnd != null and child == self.overlay_cancel_hwnd.?);
    }

    pub fn overlayFocusSlot(self: *const Host, child: HWND) ?OverlayFocusSlot {
        if (self.overlay_edit_hwnd != null and child == self.overlay_edit_hwnd.?) return .edit;
        if (self.overlay_preview_hwnd != null and child == self.overlay_preview_hwnd.?) return .preview;
        if (self.overlay_accept_hwnd != null and child == self.overlay_accept_hwnd.?) return .accept;
        if (self.overlay_cancel_hwnd != null and child == self.overlay_cancel_hwnd.?) return .cancel;
        return null;
    }

    pub fn focusRelativeOverlayControl(self: *Host, current: HWND, reverse: bool) bool {
        const current_slot = self.overlayFocusSlot(current) orelse return false;
        const target_slot = nextVisibleOverlayFocusSlot(
            self.overlay_mode,
            current_slot,
            reverse,
            self.overlay_edit_hwnd != null and sys.IsWindowVisible(self.overlay_edit_hwnd.?) != 0,
            self.overlay_preview_hwnd != null and sys.IsWindowVisible(self.overlay_preview_hwnd.?) != 0,
            self.overlay_accept_hwnd != null and sys.IsWindowVisible(self.overlay_accept_hwnd.?) != 0,
            self.overlay_cancel_hwnd != null and sys.IsWindowVisible(self.overlay_cancel_hwnd.?) != 0,
        ) orelse return false;
        const target = switch (target_slot) {
            .edit => self.overlay_edit_hwnd,
            .preview => self.overlay_preview_hwnd,
            .accept => self.overlay_accept_hwnd,
            .cancel => self.overlay_cancel_hwnd,
        } orelse return false;
        _ = sys.SetFocus(target);
        return sys.GetFocus() == target;
    }
};
