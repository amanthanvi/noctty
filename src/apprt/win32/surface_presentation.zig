//! Win32 surface presentation, extracted without changing transition order.
const win32 = @import("../win32.zig");
const runtime = win32.surface_presentation_runtime;
const App = runtime.App;
const Host = runtime.Host;
const Surface = runtime.Surface;
const UINT = runtime.UINT;
const apprt = runtime.apprt;
const c = runtime.c;
const first_frame = runtime.first_frame;
const lastError = runtime.lastError;
const log = runtime.log;
const rendererpkg = runtime.rendererpkg;
const std = runtime.std;
const sys = runtime.sys;
const windows = runtime.windows;
const test_runtime = if (@import("builtin").is_test) win32.surface_presentation_test_runtime else struct {};
const Tab = test_runtime.Tab;
const builtin = test_runtime.builtin;
const createTestHostWindow = test_runtime.createTestHostWindow;

pub fn rendererRepaintModeThisTick(self: *App, host: ?*const Host) SurfaceRepaintRequestMode {
    return rendererTickRepaintMode(
        rendererRepaintRequestMode(host, sys.GetTickCount64()),
        &self.renderer_sync_paint_spent,
    );
}

pub fn ensureResizeSettleTimer(self: *Host) void {
    if (self.resize_settle_timer_active) return;
    const hwnd = self.hwnd orelse return;
    const prev = sys.SetTimer(hwnd, c.RESIZE_SETTLE_TIMER_ID, c.RESIZE_SETTLE_TIMER_INTERVAL_MS, null);
    if (prev == 0) {
        std.log.warn("resize-settle: SetTimer failed; final pane repaint may wait for input", .{});
        return;
    }
    self.resize_settle_timer_active = true;
}

pub fn killResizeSettleTimer(self: *Host) void {
    if (!self.resize_settle_timer_active) return;
    const hwnd = self.hwnd orelse {
        self.resize_settle_timer_active = false;
        return;
    };
    _ = sys.KillTimer(hwnd, c.RESIZE_SETTLE_TIMER_ID);
    self.resize_settle_timer_active = false;
}

pub fn startResizeSettleRepaints(self: *Host) void {
    self.resize_settle_repaint_ticks = c.RESIZE_SETTLE_REPAINT_TICKS;
    self.resize_settle_until_ms = sys.GetTickCount64() +| resize_settle_deadline_ms;
    self.ensureResizeSettleTimer();
}

pub fn tickResizeSettleRepaint(self: *Host) void {
    if (self.resize_settle_repaint_ticks == 0) {
        self.killResizeSettleTimer();
        return;
    }

    self.forceVisibleSurfaceRepaintsNow();
    self.forceHostCompositionPaint();
    self.resize_settle_repaint_ticks -= 1;
    if (self.resize_settle_repaint_ticks == 0) self.killResizeSettleTimer();
}

/// Drive the one-shot post-show frame handshake for every surface this
/// host actually puts on screen.
///
/// `surfaces_visible` already accounts for hidden, minimized and
/// DWM-cloaked, so gating on it means a window that is shown but still
/// cloaked does not spend the one-shot; the refresh that observes the
/// uncloak gets it instead. See `win32/first_frame.zig` (#224).
pub fn noteFirstFrameShown(self: *Host) void {
    if (!self.surfaces_visible) return;
    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.window_visible) entry.view.noteFirstFrame(.host_shown);
        }
    }
}

pub fn shouldDeferSurfaceRepaints(self: *const Host) bool {
    return self.is_live_resize.load(.acquire) or self.defer_surface_repaints_until_flush;
}

pub fn flushDeferredVisibleSurfaceRepaints(self: *Host) void {
    self.flushDeferredVisibleSurfaceRepaintsWith(struct {
        fn repaint(surface: *Surface) !void {
            try surface.queuePaintRequest(true);
        }
    }.repaint);
}

pub fn flushDeferredVisibleSurfaceRepaintsWith(self: *Host, repaint_fn: anytype) void {
    if (self.activeTab()) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (!entry.view.window_visible) continue;
            _ = entry.view.flushDeferredLiveResizeRepaint(repaint_fn) catch |err| {
                log.err("win32 deferred live-resize repaint flush failed err={}", .{err});
            };
        }
    }
}

pub fn applyDpiChangeToVisibleSurfaces(self: *Host) void {
    if (self.activeTab()) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (!entry.view.window_visible) continue;
            entry.view.applyDpiChange();
        }
    }
}

pub fn syncVisibleSurfaceCoreSizesFromClientRects(self: *Host) void {
    if (self.activeTab()) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (!entry.view.window_visible) continue;
            entry.view.syncCoreSizeFromClientRect();
        }
    }
}

pub fn forceVisibleSurfaceRepaintsNow(self: *Host) void {
    if (self.activeTab()) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (!entry.view.window_visible) continue;
            entry.view.syncCoreSizeFromClientRect();
            entry.view.invalidateSearchBarChildPaint();
            switch (resizeSettleSurfaceAction(entry.view.shouldDrawRendererPaintContent())) {
                .present_renderer => entry.view.queuePaintRequest(true) catch |err| {
                    entry.view.cancelRendererRepaintRequest();
                    log.err("win32 resize-settle renderer paint request failed err={}", .{err});
                },
                .wake_renderer => entry.view.requestRendererFrameNow(.apprt_resize_settle),
            }
        }
    }
}

pub fn invalidateVisibleSurfaceChildPaint(
    self: *Host,
    repaint_hosted_child: bool,
    repaint_search_controls: bool,
) void {
    const defer_surface_repaints = repaint_hosted_child and self.shouldDeferSurfaceRepaints();
    if (self.activeTab()) |tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (!entry.view.window_visible) continue;

            if (repaint_hosted_child) {
                if (defer_surface_repaints) {
                    entry.view.markLiveResizeRepaintDeferred();
                } else {
                    entry.view.repaintHostedChild() catch |err| {
                        log.err("win32 hosted child repaint request failed err={}", .{err});
                    };
                }
            }

            if (repaint_search_controls) entry.view.invalidateSearchBarChildPaint();
        }
    }
}

pub const SurfaceRepaintRequestMode = enum {
    queue,
    update_now,
    defer_until_flush,
};

pub const ResizeSettleSurfaceAction = enum {
    wake_renderer,
    present_renderer,
};

pub const RendererHealthSurfaceAction = enum {
    clear_recovery,
    recover_with_followup_repaint,
};

/// Settle mode normally ends with its timer's last tick. Its 12 ticks of 16 ms
/// can take about twice that, because at the default 15.6 ms clock resolution
/// a 16 ms timer fires about every 31 ms, so the deadline only cuts settle
/// short when a busy pump starves WM_TIMER.
pub const resize_settle_deadline_ms: u64 = 2 * @as(u64, c.RESIZE_SETTLE_REPAINT_TICKS) * c.RESIZE_SETTLE_TIMER_INTERVAL_MS;

pub fn resizeSettleActive(h: *const Host, now_ms: u64) bool {
    return h.resize_settle_timer_active and now_ms < h.resize_settle_until_ms;
}

pub fn surfaceRepaintRequestMode(host: ?*const Host, now_ms: u64) SurfaceRepaintRequestMode {
    const h = host orelse return .queue;
    if (h.is_live_resize.load(.acquire)) return .defer_until_flush;
    if (resizeSettleActive(h, now_ms)) return .update_now;
    return .queue;
}

pub fn rendererRepaintRequestMode(host: ?*const Host, now_ms: u64) SurfaceRepaintRequestMode {
    return surfaceRepaintRequestMode(host, now_ms);
}

/// Renderer frames reach the UI thread as `redraw_surface` mailbox messages,
/// and `App.drainMailbox` pops until the mailbox is empty. An `update_now`
/// paint blocks in SwapBuffers until vblank and only then releases the
/// surface's repaint reservation, so when a present takes longer than the
/// renderer's frame interval (a 60 Hz display against the 8 ms animation
/// timer, or heavy output) the next frame is usually queued before the drain
/// looks again. With every frame painted synchronously, drains ran back to
/// back, and each frame also posted a WAKE, which outranks input and WM_TIMER:
/// the backlog grew faster than the pump retired it, and typing waited for
/// seconds (#297). One synchronous paint per core-app tick keeps settle mode's
/// prompt present; later frames in the same tick queue an invalidate, whose
/// WM_PAINT ranks below input.
pub fn rendererTickRepaintMode(
    mode: SurfaceRepaintRequestMode,
    sync_paint_spent: *bool,
) SurfaceRepaintRequestMode {
    if (mode != .update_now) return mode;
    if (sync_paint_spent.*) return .queue;
    sync_paint_spent.* = true;
    return mode;
}

pub fn surfaceSizeChangeRepaintMode(host: ?*const Host, now_ms: u64) SurfaceRepaintRequestMode {
    const h = host orelse return .queue;
    if (h.is_live_resize.load(.acquire) or resizeSettleActive(h, now_ms)) return .update_now;
    return .queue;
}

pub fn surfaceSizeChangePrimesRenderer(repaint_mode: SurfaceRepaintRequestMode) bool {
    return repaint_mode == .update_now;
}

pub fn resizeSettleSurfaceAction(renderer_repaint_requested: bool) ResizeSettleSurfaceAction {
    return if (renderer_repaint_requested) .present_renderer else .wake_renderer;
}

pub fn rendererHealthSurfaceAction(health: rendererpkg.Health) RendererHealthSurfaceAction {
    return switch (health) {
        .healthy => .clear_recovery,
        .unhealthy => .recover_with_followup_repaint,
    };
}

pub fn surfacePixelSizeChanged(previous: apprt.SurfaceSize, next: apprt.SurfaceSize) bool {
    return previous.width != next.width or previous.height != next.height;
}

/// Reserve the repaint slot for a renderer frame before the expensive
/// `updateFrame` work, so a paint that completes during that work cannot
/// be lost.
pub fn beginRendererFrameUpdate(self: *Surface) bool {
    return self.beginRendererRepaintRequest();
}

/// Close the interleaving where paint completion clears the reservation
/// and checks retry_pending after the renderer observed the old pending
/// reservation but before it publishes retry_pending. Either the paint
/// completion consumes the retry and sends a wake, or this requester
/// reacquires the now-idle reservation and continues immediately.
pub fn completeRendererRepaintCoalesce(self: *Surface) bool {
    if (self.renderer_repaint_requested.load(.acquire)) return false;
    if (!self.renderer_repaint_retry_pending.swap(false, .acq_rel)) return false;
    if (self.renderer_repaint_requested.cmpxchgStrong(
        false,
        true,
        .acq_rel,
        .acquire,
    ) == null) return true;

    // Another renderer request acquired the reservation between the
    // idle observation and CAS. Its paint must retain our retry.
    self.renderer_repaint_retry_pending.store(true, .release);
    return false;
}

pub fn beginRendererRepaintRequest(self: *Surface) bool {
    if (!self.renderer_repaint_requested.swap(true, .acq_rel)) {
        self.render_trace.noteRendererRepaintAccepted();
        return true;
    }
    self.renderer_repaint_retry_pending.store(true, .release);
    if (self.completeRendererRepaintCoalesce()) {
        self.render_trace.noteRendererRepaintAccepted();
        return true;
    }
    self.render_trace.noteRendererRepaintCoalesced();
    return false;
}

pub fn cancelRendererRepaintRequest(self: *Surface) void {
    self.renderer_repaint_requested.store(false, .release);
    self.renderer_repaint_retry_pending.store(false, .release);
}

pub fn consumeRendererRepaintRetryPending(self: *Surface) bool {
    return self.renderer_repaint_retry_pending.swap(false, .acq_rel);
}

pub fn shouldDrawRendererPaintContent(self: *Surface) bool {
    return self.renderer_repaint_requested.load(.acquire);
}

pub fn finishRendererRepaintRequest(self: *Surface) void {
    self.renderer_repaint_requested.store(false, .release);
    // As `requestRendererFrameNow`: a surface whose core is not running
    // has no renderer to wake.
    if (self.consumeRendererRepaintRetryPending() and self.core_initialized) {
        self.core_surface.renderer_state.noteWakeSource(.apprt_repaint_retry);
        self.core_surface.renderer_thread.wakeup.notify() catch |err| {
            log.warn("win32 renderer repaint retry wake failed err={}", .{err});
        };
    }
}

pub fn requestRendererFrameNow(
    self: *Surface,
    source: rendererpkg.State.WakeSource,
) void {
    if (!self.core_initialized) return;
    self.core_surface.renderer_state.noteWakeSource(source);
    self.core_surface.renderer_thread.wakeup.notify() catch |err| {
        log.warn("win32 renderer frame wake failed err={}", .{err});
    };
}

pub fn handleRendererHealth(self: *Surface, health: rendererpkg.Health) bool {
    switch (rendererHealthSurfaceAction(health)) {
        .clear_recovery => {
            self.cancelRendererRepaintRequest();
            return true;
        },
        .recover_with_followup_repaint => {
            _ = self.beginRendererRepaintRequest();
            self.renderer_repaint_retry_pending.store(true, .release);
            self.requestRepaintWithMode(self.app.rendererRepaintModeThisTick(self.host)) catch |err| {
                log.warn("win32 renderer health repaint request failed err={}", .{err});
                return false;
            };
            self.requestRendererFrameNow(.apprt_health_recovery);
            return true;
        },
    }
}

pub fn markLiveResizeRepaintDeferred(self: *Surface) void {
    self.live_resize_repaint_deferred = true;
}

pub fn queuePaintRequest(self: *Surface, update_now: bool) !void {
    const hwnd = self.hwnd orelse return error.NoWindow;
    self.render_trace.noteQueuePaint(update_now);
    if (self.paint_pending) {
        if (update_now) {
            self.requestRendererFrameNow(.apprt_paint_pending);
            try self.forcePaintRequestNow();
        }
        return;
    }

    self.paint_pending = true;
    errdefer self.paint_pending = false;

    if (sys.InvalidateRect(hwnd, null, 0) == 0) {
        return lastError();
    }
    if (update_now) _ = sys.UpdateWindow(hwnd);
}

pub fn forcePaintRequestNow(self: *Surface) !void {
    const hwnd = self.hwnd orelse return error.NoWindow;
    self.render_trace.noteForcePaintNow();
    self.paint_pending = false;
    const flags: UINT = c.RDW_INVALIDATE | c.RDW_INTERNALPAINT | c.RDW_UPDATENOW;
    if (sys.RedrawWindow(hwnd, null, null, flags) == 0) {
        return lastError();
    }
}

/// Feed the one-shot post-show handshake and act on its verdict.
///
/// See `win32/first_frame.zig` for why this edge has to exist at all.
/// The action is deliberately asynchronous: `noteFirstFrame(.host_shown)`
/// runs inside the `ShowWindow` call at the end of `Surface.init`, and
/// forcing a synchronous `WM_PAINT` there would re-enter
/// `core_surface.draw()` before the shell entity and window state have
/// been committed. An invalidate that the normal pump answers is enough,
/// because the pump is running by the time anything can observe it.
pub fn noteFirstFrame(self: *Surface, event: first_frame.Event) void {
    switch (self.first_frame.observe(event)) {
        .none => {},
        .request_frame => self.requestFirstFrame(),
    }
}

pub fn requestFirstFrame(self: *Surface) void {
    // The renderer thread does no work at all while it believes the
    // surface is invisible (`Pacer.intervalMs` returns null), and
    // the occlusion state it was given was computed while the host window
    // was still hidden. Re-assert it before asking for a frame; both
    // `syncOcclusion` and `occlusionCallback` are no-ops when the state
    // already agrees.
    self.syncOcclusion();
    self.requestRendererFrameNow(.apprt_first_show);

    // Not `queuePaintRequest`: that drops the invalidate whenever
    // `paint_pending` is already set, which is exactly the latch that can
    // be stuck from a paint request made while the window was hidden.
    // Going straight to `RedrawWindow` re-arms the update region without
    // `RDW_UPDATENOW`, so the paint is answered by the message pump
    // rather than re-entrantly here.
    const hwnd = self.hwnd orelse return;
    const flags: UINT = c.RDW_INVALIDATE | c.RDW_INTERNALPAINT;
    if (sys.RedrawWindow(hwnd, null, null, flags) == 0) {
        log.warn(
            "win32 first-frame invalidate failed err={}",
            .{windows.kernel32.GetLastError()},
        );
    }
}

pub fn flushDeferredLiveResizeRepaint(self: *Surface, repaint_fn: anytype) !bool {
    if (!self.live_resize_repaint_deferred) return false;
    if (self.paint_pending) {
        self.live_resize_repaint_deferred = false;
        return true;
    }

    try repaint_fn(self);
    self.live_resize_repaint_deferred = false;
    return true;
}

pub fn repaintHostedChild(self: *Surface) !void {
    if (self.live_resize_repaint_deferred) {
        _ = try self.flushDeferredLiveResizeRepaint(struct {
            fn repaint(surface: *Surface) !void {
                try surface.queuePaintRequest(true);
            }
        }.repaint);
        return;
    }

    try self.queuePaintRequest(true);
}

pub fn requestRepaintWithMode(self: *Surface, repaint_mode: SurfaceRepaintRequestMode) !void {
    _ = self.hwnd orelse return;
    if (repaint_mode == .defer_until_flush) {
        self.markLiveResizeRepaintDeferred();
        return;
    }
    self.queuePaintRequest(repaint_mode == .update_now) catch |err| {
        self.cancelRendererRepaintRequest();
        return err;
    };
}

pub fn requestRepaint(self: *Surface) !void {
    // During an interactive drag-resize the OS drives WM_SIZE →
    // WM_PAINT on every mouse-delta; stacking additional
    // InvalidateRect calls from the renderer thread just piles
    // pressure onto the pump without producing extra visible
    // frames. Drop the wake and let the WM_SIZE-driven cadence
    // own pacing. WM_EXITSIZEMOVE and layout finish with
    // `InvalidateRect` on the host plus hosted child HWNDs so nothing
    // is permanently lost.
    //
    // Gate on THIS surface's own Host — an App-wide flag would
    // freeze background windows whenever any foreground window
    // enters a drag. Surfaces outside a Host (quick-terminal
    // pre-host-attach, pre-init paint) fall through without
    // gating.
    const repaint_mode = surfaceRepaintRequestMode(self.host, sys.GetTickCount64());
    try self.requestRepaintWithMode(repaint_mode);
}

/// Refresh `self.size` from `GetClientRect` and notify the core. Call this
/// after `MoveWindow` from `Host.layout` as well as from `WM_SIZE`: with
/// `bRepaint = false`, the child can receive `WM_PAINT` before `WM_SIZE`,
/// leaving a stale screen size until the next resize event. Before the
/// core is initialized this only records the size; `Surface.init` hands
/// the core whatever it missed as soon as init finishes.
pub fn syncCoreSizeFromClientRect(self: *Surface) void {
    // A drag onto a monitor of another DPI resizes the window to its new
    // size before `WM_DPICHANGED` changes the font, and the core would
    // lay the old font out in that size: on 144 -> 96 DPI, about 66
    // columns, which wraps long lines and can push them into scrollback.
    // Hold the size until the new font is in; `applyDpiChange` syncs it
    // afterwards. Nothing is recorded, so that sync sees it.
    if (self.host) |host| if (host.dpi_change_pending) return;
    self.syncCoreSizeNow();
}

pub fn syncCoreSizeNow(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const next_size = self.app.clientSize(hwnd) catch return;
    if (!surfacePixelSizeChanged(self.size, next_size)) return;
    self.size = next_size;

    if (!self.core_initialized) return;
    self.core_surface.sizeCallback(self.size) catch |err| {
        log.err("win32 size callback failed err={}", .{err});
    };
}

/// The new DPI's font, then the client size, as one terminal resize:
/// the core batches the resize each of them sends, so termio never lays
/// out the old pixel size in the new cells, however long the font takes.
pub fn applyDpiChange(self: *Surface) void {
    if (!self.core_initialized) return self.syncContentScaleToHostDpiNow();
    self.core_surface.beginResizeBatch();
    defer self.core_surface.endResizeBatch();
    self.syncContentScaleToHostDpiNow();
    self.syncCoreSizeNow();
}

/// Hold this pane's terminal resizes until `endCoreResizeBatch`, which
/// sends one with the size and cells as they are then. A pane of a tab
/// that was hidden while its window moved to another DPI gets its new
/// size and its new font as separate resizes when it is shown, in either
/// order (`Host.layout` places it, then `setVisible` puts the font in;
/// a zoomed pane and `Host.showTabPanes` put the font in first). On its
/// own the first is the wrong grid, the new pixel size in the old cells or
/// the old one in the new cells (66x18 where the pane ends at 93x29,
/// measured on a move from 144 to 96 DPI), which termio applies when the
/// font build outlasts its 25 ms coalescing and which wraps long lines
/// into scrollback. So `Host.layout` wraps each pane it places in one,
/// and `Host.showTabPanes` the whole tab. Returns whether a batch was
/// opened; there is none before the core exists.
pub fn beginCoreResizeBatch(self: *Surface) bool {
    if (!self.core_initialized) return false;
    self.core_surface.beginResizeBatch();
    return true;
}

pub fn endCoreResizeBatch(self: *Surface, opened: bool) void {
    if (opened and self.core_initialized) self.core_surface.endResizeBatch();
}

test "a pane's resize batch needs a started core" {
    var surface: Surface = undefined;
    surface.core_initialized = false;
    // Before `Surface.init` starts the core, its storage is not a core.
    surface.core_surface.resize_batch = .{};
    const opened = surface.beginCoreResizeBatch();
    try std.testing.expect(!opened);
    surface.endCoreResizeBatch(opened);
    try std.testing.expectEqual(@as(u8, 0), surface.core_surface.resize_batch.depth);

    surface.core_initialized = true;
    try std.testing.expect(surface.beginCoreResizeBatch());
    try std.testing.expectEqual(@as(u8, 1), surface.core_surface.resize_batch.depth);
    // No resize was held, so closing it sends nothing (`core_surface.io`
    // is not set up here, and is not touched).
    surface.endCoreResizeBatch(true);
    try std.testing.expectEqual(@as(u8, 0), surface.core_surface.resize_batch.depth);
}

pub fn windowSizeChanged(self: *Surface) void {
    self.syncCoreSizeFromClientRect();

    // Quick select holds a viewport snapshot plus the cell metrics that
    // were current when it opened. A resize or font-size change invalidates
    // both, so labels would land on the wrong cells; close it instead of
    // repositioning a stale overlay.
    self.closeQuickSelect(true);

    // `MoveWindow(..., bRepaint = false)` resizes the child HWND without
    // guaranteeing a follow-up paint for the newly exposed pixels. Request
    // one from the child itself after `WM_SIZE`, when the default
    // framebuffer and client rect have both advanced to the new size.
    const repaint_mode = surfaceSizeChangeRepaintMode(self.host, sys.GetTickCount64());
    if (surfaceSizeChangePrimesRenderer(repaint_mode)) _ = self.beginRendererRepaintRequest();
    self.requestRepaintWithMode(repaint_mode) catch |err| {
        log.err("win32 size-change repaint request failed err={}", .{err});
    };
}

test "win32 renderer repaint request coalesces until paint completes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.renderer_repaint_requested = .init(false);
    surface.renderer_repaint_retry_pending = .init(false);

    try std.testing.expect(surface.beginRendererRepaintRequest());
    try std.testing.expect(!surface.beginRendererRepaintRequest());
    try std.testing.expect(surface.consumeRendererRepaintRetryPending());
    try std.testing.expect(!surface.consumeRendererRepaintRetryPending());

    surface.cancelRendererRepaintRequest();
    try std.testing.expect(surface.beginRendererRepaintRequest());

    surface.finishRendererRepaintRequest();
    try std.testing.expect(surface.beginRendererRepaintRequest());
}

test "win32 paint draws terminal content only for renderer-requested frames" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.renderer_repaint_requested = .init(false);
    try std.testing.expect(!surface.shouldDrawRendererPaintContent());

    surface.renderer_repaint_requested = .init(true);
    try std.testing.expect(surface.shouldDrawRendererPaintContent());
}

test "win32 requestRepaint preserves renderer request during live resize" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var host: Host = undefined;
    host.is_live_resize = .init(true);

    var surface: Surface = undefined;
    surface.hwnd = @ptrFromInt(1);
    surface.host = &host;
    surface.paint_pending = false;
    surface.renderer_repaint_requested = .init(true);

    try surface.requestRepaint();

    try std.testing.expect(surface.renderer_repaint_requested.load(.acquire));
    try std.testing.expect(surface.live_resize_repaint_deferred);
    try std.testing.expect(!surface.paint_pending);
}

test "win32 flushDeferredVisibleSurfaceRepaints schedules deferred visible surface once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var active_surface: Surface = undefined;
    active_surface.window_visible = true;
    active_surface.live_resize_repaint_deferred = true;
    active_surface.paint_pending = false;

    var inactive_surface: Surface = undefined;
    inactive_surface.window_visible = true;
    inactive_surface.live_resize_repaint_deferred = true;
    inactive_surface.paint_pending = false;

    var host: Host = undefined;
    host.tabs = .empty;
    host.active_tab = 0;
    defer {
        for (host.tabs.items) |*tab| tab.deinit();
        host.tabs.deinit(std.testing.allocator);
    }

    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &active_surface));
    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 2, &inactive_surface));

    var queue_calls: usize = 0;
    const TestRepaint = struct {
        var counter: *usize = undefined;

        fn repaint(surface: *Surface) !void {
            surface.paint_pending = true;
            counter.* += 1;
        }
    };
    TestRepaint.counter = &queue_calls;

    host.flushDeferredVisibleSurfaceRepaintsWith(TestRepaint.repaint);

    try std.testing.expectEqual(@as(usize, 1), queue_calls);
    try std.testing.expect(active_surface.paint_pending);
    try std.testing.expect(!active_surface.live_resize_repaint_deferred);
    try std.testing.expect(inactive_surface.live_resize_repaint_deferred);

    host.flushDeferredVisibleSurfaceRepaintsWith(TestRepaint.repaint);

    try std.testing.expectEqual(@as(usize, 1), queue_calls);
}

test "win32 first-frame one-shot survives a cloaked show and fires on uncloak" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var host: Host = undefined;
    host.id = 224;
    host.tabs = .empty;
    host.active_tab = 0;
    host.surfaces_visible = false;
    defer {
        for (host.tabs.items) |*tab| tab.deinit();
        host.tabs.deinit(std.testing.allocator);
    }

    // `core_initialized = false` and `hwnd = null` make every side effect of
    // `requestFirstFrame` a no-op, so this test observes only the gating.
    var on_screen: Surface = undefined;
    on_screen.host = &host;
    on_screen.host_id = host.id;
    on_screen.hwnd = null;
    on_screen.core_initialized = false;
    on_screen.window_visible = true;
    on_screen.first_frame = .{};

    var background_tab: Surface = undefined;
    background_tab.host = &host;
    background_tab.host_id = host.id;
    background_tab.hwnd = null;
    background_tab.core_initialized = false;
    background_tab.window_visible = false;
    background_tab.first_frame = .{};

    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &on_screen));
    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 2, &background_tab));

    // `ShowWindow` ran but DWM still reports the window cloaked, so
    // `refreshSurfaceVisibilityObserving` left `surfaces_visible` false. The
    // show must not spend the one-shot: nothing is on screen to paint yet.
    host.noteFirstFrameShown();
    try std.testing.expect(!on_screen.first_frame.shown_requested);

    // The uncloak arrives as a WinEvent with no window message behind it
    // (`onHostCloakEvent`), so it reaches the handshake only because the call
    // lives in `refreshSurfaceVisibilityObserving` rather than in the show
    // and window-position message handlers. Without that, this window would
    // never get its post-show frame.
    host.surfaces_visible = true;
    host.noteFirstFrameShown();
    try std.testing.expect(on_screen.first_frame.shown_requested);
    // A surface in a background tab is not on screen, so it keeps its
    // one-shot for whenever its tab is actually activated.
    try std.testing.expect(!background_tab.first_frame.shown_requested);

    // A second uncloak, a restore from minimized, a virtual-desktop switch
    // back: all free once the latch is spent.
    on_screen.first_frame.shown_requested = false;
    host.noteFirstFrameShown();
    try std.testing.expect(on_screen.first_frame.shown_requested);

    // And once a real swap has settled the handshake, nothing rearms it. This
    // is what keeps `refreshSurfaceVisibilityObserving` -- which runs on every
    // non-live-resize `WM_WINDOWPOSCHANGED` -- from becoming a wake source and
    // regressing the #134 idle budget.
    on_screen.first_frame.shown_requested = false;
    on_screen.first_frame.settled = true;
    host.noteFirstFrameShown();
    try std.testing.expect(!on_screen.first_frame.shown_requested);
}

/// Both the surface's and the renderer's repaint requests queue outside
/// resize, paint at once while a resize settles, and wait for the flush
/// during a live resize.
fn expectSettleRepaintModes(comptime mode: fn (?*const Host, u64) SurfaceRepaintRequestMode) !void {
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, mode(null, 1000));

    var host: Host = undefined;
    host.is_live_resize = .init(false);
    host.resize_settle_timer_active = false;
    host.resize_settle_until_ms = 0;
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, mode(&host, 1000));

    host.resize_settle_timer_active = true;
    host.resize_settle_until_ms = 1000 + resize_settle_deadline_ms;
    try std.testing.expectEqual(SurfaceRepaintRequestMode.update_now, mode(&host, 1000));

    host.is_live_resize = .init(true);
    try std.testing.expectEqual(SurfaceRepaintRequestMode.defer_until_flush, mode(&host, 1000));
}

test "win32 surfaceRepaintRequestMode flushes renderer paints during resize settle" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectSettleRepaintModes(surfaceRepaintRequestMode);
}

test "win32 rendererRepaintRequestMode paints synchronously only during resize settle" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectSettleRepaintModes(rendererRepaintRequestMode);
}

test "win32 resize settle paint mode ends with its timer or at its deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var host: Host = undefined;
    host.hwnd = null;
    host.is_live_resize = .init(false);
    host.resize_settle_timer_active = false;
    const start_ms = sys.GetTickCount64();
    host.startResizeSettleRepaints();
    try std.testing.expect(host.resize_settle_until_ms >= start_ms + resize_settle_deadline_ms);
    try std.testing.expect(host.resize_settle_until_ms <= sys.GetTickCount64() + resize_settle_deadline_ms);

    // The timer's last tick ends settle mode before the deadline.
    host.resize_settle_timer_active = false;
    host.resize_settle_until_ms = 5000;
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, rendererRepaintRequestMode(&host, 4999));
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, surfaceSizeChangeRepaintMode(&host, 4999));

    // A busy pump delays WM_TIMER, so the timer can still be armed, with
    // repaint ticks left, after the deadline has passed.
    host.resize_settle_timer_active = true;
    host.resize_settle_repaint_ticks = c.RESIZE_SETTLE_REPAINT_TICKS;
    host.resize_settle_until_ms = 5000;
    try std.testing.expectEqual(SurfaceRepaintRequestMode.update_now, rendererRepaintRequestMode(&host, 4999));
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, rendererRepaintRequestMode(&host, 5000));
    try std.testing.expectEqual(SurfaceRepaintRequestMode.update_now, surfaceSizeChangeRepaintMode(&host, 4999));
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, surfaceSizeChangeRepaintMode(&host, 5000));
}

test "win32 a core-app tick spends at most one synchronous renderer paint" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var spent = false;
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, rendererTickRepaintMode(.queue, &spent));
    try std.testing.expectEqual(SurfaceRepaintRequestMode.defer_until_flush, rendererTickRepaintMode(.defer_until_flush, &spent));
    try std.testing.expect(!spent);

    try std.testing.expectEqual(SurfaceRepaintRequestMode.update_now, rendererTickRepaintMode(.update_now, &spent));
    try std.testing.expect(spent);
    // Every later settle-mode frame in the same tick queues, so the pump can
    // reach input before it paints again.
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, rendererTickRepaintMode(.update_now, &spent));
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, rendererTickRepaintMode(.update_now, &spent));
    try std.testing.expectEqual(SurfaceRepaintRequestMode.defer_until_flush, rendererTickRepaintMode(.defer_until_flush, &spent));

    // The App's per-tick budget, as `tickCoreApp` resets it for each tick.
    var host: Host = undefined;
    host.is_live_resize = .init(false);
    host.resize_settle_timer_active = true;
    host.resize_settle_until_ms = std.math.maxInt(u64);
    var app: App = undefined;
    app.renderer_sync_paint_spent = false;
    try std.testing.expectEqual(SurfaceRepaintRequestMode.update_now, app.rendererRepaintModeThisTick(&host));
    try std.testing.expectEqual(SurfaceRepaintRequestMode.queue, app.rendererRepaintModeThisTick(&host));
    app.renderer_sync_paint_spent = false;
    try std.testing.expectEqual(SurfaceRepaintRequestMode.update_now, app.rendererRepaintModeThisTick(&host));
}

test "win32 renderer health policy recovers unhealthy frames and clears healthy state" {
    try std.testing.expectEqual(
        RendererHealthSurfaceAction.clear_recovery,
        rendererHealthSurfaceAction(.healthy),
    );
    try std.testing.expectEqual(
        RendererHealthSurfaceAction.recover_with_followup_repaint,
        rendererHealthSurfaceAction(.unhealthy),
    );
}

test "win32 resize settle presents pending renderer frames before waking renderer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(
        ResizeSettleSurfaceAction.wake_renderer,
        resizeSettleSurfaceAction(false),
    );
    try std.testing.expectEqual(
        ResizeSettleSurfaceAction.present_renderer,
        resizeSettleSurfaceAction(true),
    );
}

test "win32 surface size-change repaint stays synchronous during live resize" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(
        SurfaceRepaintRequestMode.queue,
        surfaceSizeChangeRepaintMode(null, 1000),
    );

    var host: Host = undefined;
    host.is_live_resize = .init(false);
    host.resize_settle_timer_active = false;
    host.resize_settle_until_ms = 0;
    try std.testing.expectEqual(
        SurfaceRepaintRequestMode.queue,
        surfaceSizeChangeRepaintMode(&host, 1000),
    );

    host.resize_settle_timer_active = true;
    host.resize_settle_until_ms = 1000 + resize_settle_deadline_ms;
    try std.testing.expectEqual(
        SurfaceRepaintRequestMode.update_now,
        surfaceSizeChangeRepaintMode(&host, 1000),
    );

    host.resize_settle_timer_active = false;
    host.is_live_resize = .init(true);
    try std.testing.expectEqual(
        SurfaceRepaintRequestMode.update_now,
        surfaceSizeChangeRepaintMode(&host, 1000),
    );

    try std.testing.expect(!surfaceSizeChangePrimesRenderer(.queue));
    try std.testing.expect(surfaceSizeChangePrimesRenderer(.update_now));
    try std.testing.expect(!surfaceSizeChangePrimesRenderer(.defer_until_flush));
}

test "win32 surfacePixelSizeChanged only trips on width or height deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const stable = apprt.SurfaceSize{ .width = 800, .height = 600 };
    try std.testing.expect(!surfacePixelSizeChanged(stable, .{ .width = 800, .height = 600 }));
    try std.testing.expect(surfacePixelSizeChanged(stable, .{ .width = 801, .height = 600 }));
    try std.testing.expect(surfacePixelSizeChanged(stable, .{ .width = 800, .height = 601 }));
}

test "win32 a pending DPI change holds the surface size and font, and the next sync catches up" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(hwnd);
    var app: App = undefined;
    var host: Host = undefined;
    host.dpi_change_pending = true;
    host.current_dpi = 144;
    host.surfaces_visible = true;
    var surface: Surface = undefined;
    surface.app = &app;
    surface.host = &host;
    surface.hwnd = hwnd;
    surface.core_initialized = false;
    surface.window_visible = true;
    surface.size = .{ .width = 0, .height = 0 };
    surface.content_scale = .{ .x = 1, .y = 1 };

    surface.syncCoreSizeFromClientRect();
    surface.syncContentScaleToHostDpi();
    try std.testing.expectEqual(apprt.SurfaceSize{ .width = 0, .height = 0 }, surface.size);
    try std.testing.expectEqual(@as(f32, 1), surface.content_scale.x);

    // Nothing was recorded while held, so the sync after the font change
    // still sees the new size.
    host.dpi_change_pending = false;
    surface.syncCoreSizeFromClientRect();
    surface.syncContentScaleToHostDpi();
    try std.testing.expectEqual(apprt.SurfaceSize{ .width = 320, .height = 240 }, surface.size);
    try std.testing.expectEqual(@as(f32, 1.5), surface.content_scale.x);
}
