//! Terminal UIA session at the Surface/provider seam.
//!
//! Owns the retained immutable snapshot, provider lifetime, query wakeups,
//! refresh cadence, event selection, and incremental spoken-output policy.
//! The Surface supplies one renderer-snapshot callback; renderer and session
//! locks are therefore never held together.

const std = @import("std");
const win32_types = @import("win32_types.zig");
const sys = @import("win32/sys.zig");
const win32_uia = @import("win32_uia/mod.zig");

const Allocator = std.mem.Allocator;
const HWND = win32_types.HWND;
const UINT = win32_types.UINT;
const WPARAM = win32_types.WPARAM;
const LPARAM = win32_types.LPARAM;
const BOOL = win32_types.BOOL;

const refresh_interval_ms: u64 = 100;
const query_activity_window_ms: u64 = 1_000;
const input_echo_window_ms: u64 = 1_000;
const cold_query_timeout_ms: UINT = 500;
const max_announcement_bytes: usize = 1_000;
const max_pending_announcements: usize = 8;
const omitted_output_notice = "terminal output omitted";
const SMTO_BLOCK: UINT = 0x0001;
const SMTO_ABORTIFHUNG: UINT = 0x0002;

const AnnouncementNormalizer = struct {
    pending_space: bool = false,
    has_text: bool = false,
};

pub const Capture = struct {
    snapshot: win32_uia.AccessibleTextSnapshot,
    cell_width: f64,
    cell_height: f64,
    origin_x: f64,
    origin_y: f64,

    pub fn deinit(self: *Capture) void {
        self.snapshot.deinit();
        self.* = undefined;
    }
};

pub const Ops = struct {
    ctx: *anyopaque,
    hwnd: *const fn (*anyopaque) ?HWND,
    name: *const fn (*anyopaque, []u8) []const u8,
    focused: *const fn (*anyopaque) bool,
    capture: *const fn (*anyopaque, Allocator) anyerror!Capture,
    defer_provider_release: *const fn (*anyopaque, *win32_uia.TerminalProvider) void,
};

pub const Change = enum { unchanged, geometry, caret, text, text_and_caret };
const SpeechMode = enum { discard, accumulate, emit };

pub const PublishPolicy = struct {
    refresh_snapshot: bool,
    emit_events: bool,
};

pub const TerminalAccessibilitySession = struct {
    alloc: Allocator,
    refcount: std.atomic.Value(u32) = .init(1),
    mutex: std.Thread.Mutex = .{},
    ops: Ops,
    query_message: UINT,
    timer_id: usize,
    attached: bool = true,
    provider: ?*win32_uia.TerminalProvider = null,
    last_query_ms: std.atomic.Value(u64) = .init(0),
    query_refresh_post_pending: std.atomic.Value(bool) = .init(false),
    last_refresh_ms: u64 = 0,
    refresh_timer_active: bool = false,
    cached_text: []u8,
    cached_name: [256]u8 = undefined,
    cached_name_len: usize = 0,
    cached_focused: std.atomic.Value(bool) = .init(false),
    cached_visible_text: []u8,
    cached_visible_range: win32_uia.OffsetRange = .{ .start = 0, .end = 0 },
    cached_caret_offset: usize = 0,
    cached_cells: []win32_uia.TerminalCellPosition,
    viewport_rows: u32 = 0,
    viewport_columns: u32 = 0,
    cell_width: f64 = 0,
    cell_height: f64 = 0,
    origin_x: f64 = 0,
    origin_y: f64 = 0,
    pending_announcements: [max_pending_announcements][max_announcement_bytes]u8 = undefined,
    pending_announcement_lengths: [max_pending_announcements]usize = [_]usize{0} ** max_pending_announcements,
    pending_announcement_omitted: [max_pending_announcements]bool = [_]bool{false} ** max_pending_announcements,
    pending_announcement_head: usize = 0,
    pending_announcement_count: usize = 0,
    pending_output_omitted: bool = false,
    announcement_normalizer: AnnouncementNormalizer = .{},
    recent_input: [256]u8 = undefined,
    recent_input_len: usize = 0,
    recent_input_matched: usize = 0,
    recent_input_complete: bool = true,
    recent_input_ms: u64 = 0,

    pub fn create(
        alloc: Allocator,
        ops: Ops,
        query_message: UINT,
        timer_id: usize,
    ) !*TerminalAccessibilitySession {
        const self = try alloc.create(TerminalAccessibilitySession);
        errdefer alloc.destroy(self);
        const cached_text = try alloc.dupe(u8, "");
        errdefer alloc.free(cached_text);
        const cached_visible_text = try alloc.dupe(u8, "");
        errdefer alloc.free(cached_visible_text);
        const cached_cells = try alloc.alloc(win32_uia.TerminalCellPosition, 0);
        errdefer alloc.free(cached_cells);
        self.* = .{
            .alloc = alloc,
            .ops = ops,
            .query_message = query_message,
            .timer_id = timer_id,
            .cached_text = cached_text,
            .cached_visible_text = cached_visible_text,
            .cached_cells = cached_cells,
        };
        self.cacheName();
        self.cached_focused.store(ops.focused(ops.ctx), .release);
        return self;
    }

    pub fn acquireProvider(self: *TerminalAccessibilitySession) !*win32_uia.TerminalProvider {
        if (self.provider) |provider| {
            _ = try self.refresh(.discard, false);
            return provider;
        }
        _ = try self.refresh(.discard, false);
        const hwnd = self.ops.hwnd(self.ops.ctx) orelse return error.NoWindow;
        self.provider = try win32_uia.TerminalProvider.create(
            self.alloc,
            hwnd,
            self.state(),
        );
        return self.provider.?;
    }

    pub fn rendererUpdated(self: *TerminalAccessibilitySession) void {
        self.publish(false, .emit);
    }

    pub fn outputInterested(self: *TerminalAccessibilitySession) bool {
        self.mutex.lock();
        const attached = self.attached;
        const provider_ready = self.provider != null;
        self.mutex.unlock();
        return semanticOutputInterestPolicy(
            attached,
            provider_ready,
            self.cached_focused.load(.acquire),
        );
    }

    pub fn handleQueryRefresh(self: *TerminalAccessibilitySession, force: bool) void {
        self.query_refresh_post_pending.store(false, .release);
        self.publish(force, .accumulate);
    }

    pub fn handleTimer(self: *TerminalAccessibilitySession) void {
        self.cancelTimer();
        self.publish(false, .emit);
    }

    /// Refresh the retained document before publishing focus. This ordering is
    /// intentional: a screen reader's first synchronous focused query must see
    /// background output and current geometry.
    pub fn focusChanged(self: *TerminalAccessibilitySession, focused_now: bool) void {
        self.cached_focused.store(focused_now, .release);
        if (!focused_now) {
            self.cancelTimer();
            self.mutex.lock();
            self.clearPendingAnnouncements();
            self.clearRecentInput();
            self.announcement_normalizer = .{};
            self.mutex.unlock();
            return;
        }
        if (self.provider == null) return;
        self.publish(true, .discard);
        if (self.provider) |provider| win32_uia.events.raiseFocusChanged(&provider.base);
    }

    pub fn nameChanged(self: *TerminalAccessibilitySession) void {
        self.mutex.lock();
        self.cacheName();
        self.mutex.unlock();
        const provider = self.provider orelse return;
        if (!win32_uia.events.clientsAreListening()) return;
        win32_uia.events.raiseNameChanged(&provider.base);
        win32_uia.events.raiseStructureChanged(
            &provider.base,
            .children_invalidated,
            null,
        );
    }

    fn cacheName(self: *TerminalAccessibilitySession) void {
        var scratch: @TypeOf(self.cached_name) = undefined;
        const name = self.ops.name(self.ops.ctx, &scratch);
        const len = @min(name.len, self.cached_name.len);
        @memmove(self.cached_name[0..len], name[0..len]);
        self.cached_name_len = len;
    }

    pub fn noteInput(self: *TerminalAccessibilitySession, input: []const u8) void {
        if (input.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (appendInputQueue(
            &self.recent_input,
            &self.recent_input_len,
            &self.recent_input_matched,
            &self.recent_input_complete,
            input,
        )) {
            self.recent_input_ms = sys.GetTickCount64();
        }
    }

    pub fn noteSemanticOutput(self: *TerminalAccessibilitySession, output: []const u8) void {
        if (output.len == 0) return;
        const should_announce = self.cached_focused.load(.acquire) and
            win32_uia.events.clientsAreListening();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.attached) return;
        const without_echo = self.stripRecentInputEcho(output, sys.GetTickCount64());
        const candidate = self.normalizeSemanticOutputLocked(
            without_echo.held_prefix,
            without_echo.output,
            should_announce,
        ) orelse return;
        defer self.alloc.free(candidate);
        if (!should_announce) return;
        self.enqueuePendingAnnouncements(candidate);
        self.armAnnouncementTimer();
    }

    fn normalizeSemanticOutputLocked(
        self: *TerminalAccessibilitySession,
        prefix: []const u8,
        output: []const u8,
        should_announce: bool,
    ) ?[]u8 {
        return normalizeSemanticAnnouncementParts(
            self.alloc,
            &self.announcement_normalizer,
            prefix,
            output,
        ) catch {
            self.clearRecentInput();
            self.announcement_normalizer = .{};
            if (should_announce) {
                self.pending_output_omitted = true;
                self.armAnnouncementTimer();
            }
            return null;
        };
    }

    pub fn resetSemanticOutputContinuity(self: *TerminalAccessibilitySession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearRecentInput();
        self.announcement_normalizer = .{};
    }

    pub fn noteOutputOmitted(self: *TerminalAccessibilitySession) void {
        self.recordOutputOmission(
            self.cached_focused.load(.acquire) and
                win32_uia.events.clientsAreListening(),
        );
    }

    fn recordOutputOmission(
        self: *TerminalAccessibilitySession,
        should_announce: bool,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.attached) return;
        self.clearRecentInput();
        self.announcement_normalizer = .{};
        if (!should_announce) return;
        self.pending_output_omitted = true;
        self.armAnnouncementTimer();
    }

    pub fn deinit(self: *TerminalAccessibilitySession) void {
        self.cancelTimer();
        self.mutex.lock();
        self.attached = false;
        self.query_refresh_post_pending.store(false, .release);
        self.mutex.unlock();
        if (self.provider) |provider| {
            self.provider = null;
            provider.detach();
            self.ops.defer_provider_release(self.ops.ctx, provider);
        }
        release(@ptrCast(self));
    }

    fn publish(
        self: *TerminalAccessibilitySession,
        force: bool,
        requested_speech_mode: SpeechMode,
    ) void {
        const provider = self.provider orelse return;
        const now_ms = sys.GetTickCount64();
        const policy = publishPolicy(
            win32_uia.events.clientsAreListening(),
            queryRecentlyActive(self.last_query_ms.load(.acquire), now_ms),
        );
        if (!force and !policy.refresh_snapshot) return;
        if (!force and !refreshDue(self.last_refresh_ms, now_ms)) {
            if (!self.refresh_timer_active) {
                const hwnd = self.ops.hwnd(self.ops.ctx) orelse return;
                if (sys.SetTimer(hwnd, self.timer_id, refreshDelay(self.last_refresh_ms, now_ms), null) != 0) {
                    self.refresh_timer_active = true;
                }
            }
            return;
        }
        self.cancelTimer();
        const started_ms = now_ms;
        const is_focused = self.cached_focused.load(.acquire);
        const speech_mode: SpeechMode = if (requested_speech_mode == .discard or !is_focused)
            .discard
        else if (requested_speech_mode == .accumulate)
            .accumulate
        else if (policy.emit_events)
            .emit
        else
            .discard;
        const result = self.refresh(speech_mode, true);
        const completed_ms = sys.GetTickCount64();
        self.last_refresh_ms = completed_ms;
        if (snapshotWasSlow(started_ms, completed_ms)) {
            std.log.warn("win32 terminal UIA snapshot slow elapsed_ms={d}", .{completed_ms -| started_ms});
        }
        const refresh_result = result catch |err| {
            std.log.warn("win32 terminal UIA snapshot refresh failed err={}", .{err});
            return;
        };
        defer if (refresh_result.announcement) |announcement| self.alloc.free(announcement);
        if (policy.emit_events) {
            switch (refresh_result.change) {
                .text => provider.raiseTextChanged(),
                .caret => provider.raiseTextSelectionChanged(),
                .text_and_caret => {
                    provider.raiseTextChanged();
                    provider.raiseTextSelectionChanged();
                },
                .unchanged, .geometry => {},
            }
            if (refresh_result.announcement) |announcement| {
                win32_uia.events.raiseTerminalOutputNotification(&provider.base, announcement);
            }
        }
        if (refresh_result.announcement_pending and !self.refresh_timer_active) {
            const hwnd = self.ops.hwnd(self.ops.ctx) orelse return;
            if (sys.SetTimer(hwnd, self.timer_id, refresh_interval_ms, null) != 0) {
                self.refresh_timer_active = true;
            }
        }
    }

    const RefreshResult = struct {
        change: Change,
        announcement: ?[]u8 = null,
        announcement_pending: bool = false,
    };

    fn refresh(
        self: *TerminalAccessibilitySession,
        speech_mode: SpeechMode,
        update_refresh_time: bool,
    ) !RefreshResult {
        // Capture obtains and releases the renderer lock. Only after it returns
        // do we take the session cache lock.
        var capture = try self.ops.capture(self.ops.ctx, self.alloc);
        defer capture.deinit();
        const snapshot = &capture.snapshot;

        const text = snapshot.text;
        snapshot.text = text[0..0];
        errdefer self.alloc.free(text);
        const cells = snapshot.cell_for_byte;
        snapshot.cell_for_byte = cells[0..0];
        errdefer self.alloc.free(cells);
        const visible_range = snapshot.visible_range;
        const caret_offset = snapshot.caret_offset;
        const visible_text = try self.alloc.dupe(u8, text[visible_range.start..visible_range.end]);
        errdefer self.alloc.free(visible_text);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.attached) {
            self.alloc.free(visible_text);
            self.alloc.free(cells);
            self.alloc.free(text);
            return .{ .change = .unchanged };
        }

        const text_changed = !std.mem.eql(u8, self.cached_text, text) or
            self.cached_visible_range.start != visible_range.start or
            self.cached_visible_range.end != visible_range.end;
        const caret_changed = self.cached_caret_offset != caret_offset;
        const unchanged = std.mem.eql(u8, self.cached_text, text) and
            self.cached_visible_range.start == visible_range.start and
            self.cached_visible_range.end == visible_range.end and
            self.cached_caret_offset == caret_offset and
            self.viewport_rows == snapshot.viewport_rows and
            self.viewport_columns == snapshot.viewport_columns and
            self.cell_width == capture.cell_width and
            self.cell_height == capture.cell_height and
            self.origin_x == capture.origin_x and
            self.origin_y == capture.origin_y and
            cellsEqual(self.cached_cells, cells);
        if (unchanged) {
            const announcement = if (speech_mode == .emit)
                try self.takePendingAnnouncement()
            else
                null;
            self.alloc.free(visible_text);
            self.alloc.free(cells);
            self.alloc.free(text);
            if (update_refresh_time) self.last_refresh_ms = sys.GetTickCount64();
            return .{
                .change = .unchanged,
                .announcement = announcement,
                .announcement_pending = self.hasPendingAnnouncement(),
            };
        }

        const announcement = if (speech_mode == .emit)
            try self.takePendingAnnouncement()
        else
            null;
        errdefer if (announcement) |value| self.alloc.free(value);

        self.alloc.free(self.cached_cells);
        self.alloc.free(self.cached_visible_text);
        self.alloc.free(self.cached_text);
        self.cached_text = text;
        self.cached_visible_text = visible_text;
        self.cached_visible_range = visible_range;
        self.cached_caret_offset = caret_offset;
        self.cached_cells = cells;
        self.viewport_rows = snapshot.viewport_rows;
        self.viewport_columns = snapshot.viewport_columns;
        self.cell_width = capture.cell_width;
        self.cell_height = capture.cell_height;
        self.origin_x = capture.origin_x;
        self.origin_y = capture.origin_y;
        if (update_refresh_time) self.last_refresh_ms = sys.GetTickCount64();
        return .{
            .change = if (text_changed and caret_changed)
                .text_and_caret
            else if (text_changed)
                .text
            else if (caret_changed)
                .caret
            else
                .geometry,
            .announcement = announcement,
            .announcement_pending = self.hasPendingAnnouncement(),
        };
    }

    fn stripRecentInputEcho(
        self: *TerminalAccessibilitySession,
        output: []const u8,
        now_ms: u64,
    ) EchoOutput {
        if (self.recent_input_len == 0) return .{ .output = output };
        if (now_ms -| self.recent_input_ms > input_echo_window_ms) {
            const held = self.recent_input[0..self.recent_input_matched];
            self.clearRecentInput();
            return .{ .held_prefix = held, .output = output };
        }
        return consumeEchoPrefix(
            &self.recent_input,
            &self.recent_input_len,
            &self.recent_input_matched,
            &self.recent_input_complete,
            output,
        );
    }

    fn clearRecentInput(self: *TerminalAccessibilitySession) void {
        self.recent_input_len = 0;
        self.recent_input_matched = 0;
        self.recent_input_complete = true;
    }

    fn takePendingAnnouncement(self: *TerminalAccessibilitySession) !?[]u8 {
        if (self.pending_announcement_count != 0) {
            const index = self.pending_announcement_head;
            const announcement = if (self.pending_announcement_omitted[index])
                try self.alloc.dupe(u8, omitted_output_notice)
            else
                try self.alloc.dupe(
                    u8,
                    self.pending_announcements[index][0..self.pending_announcement_lengths[index]],
                );
            self.pending_announcement_head = (index + 1) % max_pending_announcements;
            self.pending_announcement_count -= 1;
            self.materializePendingOmission();
            return announcement;
        }
        if (!self.pending_output_omitted) return null;
        self.pending_output_omitted = false;
        return try self.alloc.dupe(u8, omitted_output_notice);
    }

    fn hasPendingAnnouncement(self: *const TerminalAccessibilitySession) bool {
        return self.pending_announcement_count != 0 or self.pending_output_omitted;
    }

    fn clearPendingAnnouncements(self: *TerminalAccessibilitySession) void {
        self.pending_announcement_head = 0;
        self.pending_announcement_count = 0;
        self.pending_output_omitted = false;
    }

    fn materializePendingOmission(self: *TerminalAccessibilitySession) void {
        if (!self.pending_output_omitted or
            self.pending_announcement_count == max_pending_announcements) return;
        const index = (self.pending_announcement_head + self.pending_announcement_count) %
            max_pending_announcements;
        self.pending_announcement_lengths[index] = 0;
        self.pending_announcement_omitted[index] = true;
        self.pending_announcement_count += 1;
        self.pending_output_omitted = false;
    }

    fn armAnnouncementTimer(self: *TerminalAccessibilitySession) void {
        if (!self.hasPendingAnnouncement() or self.refresh_timer_active) return;
        const hwnd = self.ops.hwnd(self.ops.ctx) orelse return;
        if (sys.SetTimer(hwnd, self.timer_id, 1, null) != 0) self.refresh_timer_active = true;
    }

    fn enqueuePendingAnnouncements(
        self: *TerminalAccessibilitySession,
        announcement: []const u8,
    ) void {
        self.materializePendingOmission();
        if (self.pending_output_omitted) return;
        var remaining = announcement;
        while (remaining.len != 0) {
            if (self.pending_announcement_count == max_pending_announcements) {
                self.pending_output_omitted = true;
                return;
            }
            var chunk_len = @min(remaining.len, max_announcement_bytes);
            while (chunk_len != 0 and !std.unicode.utf8ValidateSlice(remaining[0..chunk_len])) {
                chunk_len -= 1;
            }
            if (chunk_len == 0) return;
            const index = (self.pending_announcement_head + self.pending_announcement_count) %
                max_pending_announcements;
            @memcpy(self.pending_announcements[index][0..chunk_len], remaining[0..chunk_len]);
            self.pending_announcement_lengths[index] = chunk_len;
            self.pending_announcement_omitted[index] = false;
            self.pending_announcement_count += 1;
            remaining = remaining[chunk_len..];
        }
    }

    fn cancelTimer(self: *TerminalAccessibilitySession) void {
        if (!self.refresh_timer_active) return;
        if (self.ops.hwnd(self.ops.ctx)) |hwnd| _ = sys.KillTimer(hwnd, self.timer_id);
        self.refresh_timer_active = false;
    }

    fn state(self: *TerminalAccessibilitySession) win32_uia.TerminalState {
        return .{
            .ctx = @ptrCast(self),
            .retain = retain,
            .release = release,
            .name = providerName,
            .value = providerValue,
            .snapshot = providerSnapshot,
            .focused = providerFocused,
        };
    }

    fn retain(ctx: *anyopaque) void {
        const self: *TerminalAccessibilitySession = @ptrCast(@alignCast(ctx));
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    fn release(ctx: *anyopaque) void {
        const self: *TerminalAccessibilitySession = @ptrCast(@alignCast(ctx));
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous != 1) return;
        self.alloc.free(self.cached_cells);
        self.alloc.free(self.cached_visible_text);
        self.alloc.free(self.cached_text);
        self.alloc.destroy(self);
    }

    fn providerName(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *TerminalAccessibilitySession = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.attached) return std.fmt.bufPrint(buf, "Terminal", .{}) catch "Terminal";
        const len = @min(buf.len, self.cached_name_len);
        @memcpy(buf[0..len], self.cached_name[0..len]);
        return buf[0..len];
    }

    fn providerValue(ctx: *anyopaque, alloc: Allocator) ![]u8 {
        const self: *TerminalAccessibilitySession = @ptrCast(@alignCast(ctx));
        self.noteTextQuery();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.attached) return error.ElementNotAvailable;
        return alloc.dupe(u8, self.cached_text);
    }

    fn providerSnapshot(ctx: *anyopaque, alloc: Allocator) !win32_uia.widgets.TerminalSnapshot {
        const self: *TerminalAccessibilitySession = @ptrCast(@alignCast(ctx));
        self.noteTextQuery();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.attached) return error.ElementNotAvailable;
        const document_text = try alloc.dupe(u8, self.cached_text);
        errdefer alloc.free(document_text);
        const visible_text = try alloc.dupe(u8, self.cached_visible_text);
        errdefer alloc.free(visible_text);
        const cells = try alloc.dupe(win32_uia.TerminalCellPosition, self.cached_cells);
        return .{
            .document_text = document_text,
            .visible_text = visible_text,
            .visible_range = self.cached_visible_range,
            .caret_offset = self.cached_caret_offset,
            .geometry = .{
                .cell_for_byte = cells,
                .viewport_rows = self.viewport_rows,
                .viewport_columns = self.viewport_columns,
                .cell_width = self.cell_width,
                .cell_height = self.cell_height,
                .origin_x = self.origin_x,
                .origin_y = self.origin_y,
            },
        };
    }

    fn providerFocused(ctx: *anyopaque) bool {
        const self: *TerminalAccessibilitySession = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.attached and self.cached_focused.load(.acquire);
    }

    fn noteTextQuery(self: *TerminalAccessibilitySession) void {
        const now_ms = sys.GetTickCount64();
        const previous_query_ms = self.last_query_ms.swap(now_ms, .acq_rel);
        self.mutex.lock();
        const hwnd = if (self.attached) self.ops.hwnd(self.ops.ctx) else null;
        self.mutex.unlock();
        if (hwnd == null) return;
        if (queryNeedsSynchronousRefresh(previous_query_ms, now_ms)) {
            var ignored: usize = 0;
            if (sys.SendMessageTimeoutW(
                hwnd.?,
                self.query_message,
                1,
                0,
                SMTO_BLOCK | SMTO_ABORTIFHUNG,
                cold_query_timeout_ms,
                &ignored,
            ) != 0) return;
        }
        if (self.query_refresh_post_pending.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        if (sys.PostMessageW(hwnd.?, self.query_message, 0, 0) == 0) {
            self.query_refresh_post_pending.store(false, .release);
        }
    }
};

pub fn refreshDue(last_refresh_ms: u64, now_ms: u64) bool {
    return last_refresh_ms == 0 or now_ms -| last_refresh_ms >= refresh_interval_ms;
}

pub fn refreshDelay(last_refresh_ms: u64, now_ms: u64) UINT {
    return @intCast(@max(1, refresh_interval_ms -| (now_ms -| last_refresh_ms)));
}

pub fn snapshotWasSlow(start_ms: u64, completed_ms: u64) bool {
    return completed_ms -| start_ms >= refresh_interval_ms;
}

pub fn queryRecentlyActive(last_query_ms: u64, now_ms: u64) bool {
    return last_query_ms != 0 and now_ms -| last_query_ms <= query_activity_window_ms;
}

fn semanticOutputInterestPolicy(
    attached: bool,
    provider_ready: bool,
    focused: bool,
) bool {
    // Once UIA has requested a provider, pre-arm focused output capture so a
    // listener transition cannot lose its first terminal output batch.
    return attached and provider_ready and focused;
}

pub fn queryNeedsSynchronousRefresh(last_query_ms: u64, now_ms: u64) bool {
    return !queryRecentlyActive(last_query_ms, now_ms);
}

pub fn publishPolicy(clients_listening: bool, query_recently_active: bool) PublishPolicy {
    return .{
        .refresh_snapshot = clients_listening or query_recently_active,
        .emit_events = clients_listening,
    };
}

pub fn cellsEqual(
    lhs: []const win32_uia.TerminalCellPosition,
    rhs: []const win32_uia.TerminalCellPosition,
) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |a, b| {
        if (a.row != b.row or a.column != b.column or a.width != b.width) return false;
    }
    return true;
}

const TestOps = struct {
    fn hwnd(_: *anyopaque) ?HWND {
        return null;
    }

    fn name(_: *anyopaque, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "Terminal", .{}) catch "Terminal";
    }

    fn focused(_: *anyopaque) bool {
        return true;
    }

    fn capture(_: *anyopaque, alloc: Allocator) !Capture {
        const text = try alloc.dupe(u8, "");
        errdefer alloc.free(text);
        const cells = try alloc.alloc(win32_uia.TerminalCellPosition, 0);
        return .{
            .snapshot = .{
                .alloc = alloc,
                .text = text,
                .visible_range = .{ .start = 0, .end = 0 },
                .caret_offset = 0,
                .cell_for_byte = cells,
                .viewport_rows = 0,
                .viewport_columns = 0,
            },
            .cell_width = 0,
            .cell_height = 0,
            .origin_x = 0,
            .origin_y = 0,
        };
    }

    fn deferProviderRelease(_: *anyopaque, _: *win32_uia.TerminalProvider) void {}

    fn ops(ctx: *anyopaque) Ops {
        return .{
            .ctx = ctx,
            .hwnd = hwnd,
            .name = name,
            .focused = focused,
            .capture = capture,
            .defer_provider_release = deferProviderRelease,
        };
    }
};

const MutableTestOps = struct {
    const Context = struct {
        focused: bool,
        text: []const u8,
        name: []const u8 = "Terminal",
        return_name_without_copy: bool = false,
    };

    fn hwnd(_: *anyopaque) ?HWND {
        return null;
    }

    fn name(ctx: *anyopaque, buf: []u8) []const u8 {
        const value: *Context = @ptrCast(@alignCast(ctx));
        if (value.return_name_without_copy) return value.name;
        return std.fmt.bufPrint(buf, "{s}", .{value.name}) catch "Terminal";
    }

    fn focused(ctx: *anyopaque) bool {
        const value: *Context = @ptrCast(@alignCast(ctx));
        return value.focused;
    }

    fn capture(ctx: *anyopaque, alloc: Allocator) !Capture {
        const value: *Context = @ptrCast(@alignCast(ctx));
        const text = try alloc.dupe(u8, value.text);
        errdefer alloc.free(text);
        const cells = try alloc.alloc(win32_uia.TerminalCellPosition, 0);
        return .{
            .snapshot = .{
                .alloc = alloc,
                .text = text,
                .visible_range = .{ .start = 0, .end = text.len },
                .caret_offset = text.len,
                .cell_for_byte = cells,
                .viewport_rows = 1,
                .viewport_columns = @intCast(text.len),
            },
            .cell_width = 1,
            .cell_height = 1,
            .origin_x = 0,
            .origin_y = 0,
        };
    }

    fn deferProviderRelease(_: *anyopaque, _: *win32_uia.TerminalProvider) void {}

    fn ops(ctx: *Context) Ops {
        return .{
            .ctx = ctx,
            .hwnd = hwnd,
            .name = name,
            .focused = focused,
            .capture = capture,
            .defer_provider_release = deferProviderRelease,
        };
    }
};

fn normalizeSemanticAnnouncementSlice(
    normalizer: *AnnouncementNormalizer,
    output: []u8,
    write_index: *usize,
    input: []const u8,
) !void {
    var view = try std.unicode.Utf8View.init(input);
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |sequence| {
        const cp = std.unicode.utf8Decode(sequence) catch unreachable;
        if (cp <= 0x7f and std.ascii.isWhitespace(@intCast(cp))) {
            if (normalizer.has_text) normalizer.pending_space = true;
            continue;
        }
        if (normalizer.pending_space) {
            output[write_index.*] = ' ';
            write_index.* += 1;
            normalizer.pending_space = false;
        }
        @memcpy(output[write_index.*..][0..sequence.len], sequence);
        write_index.* += sequence.len;
        normalizer.has_text = true;
    }
}

fn normalizeSemanticAnnouncementParts(
    alloc: Allocator,
    normalizer: *AnnouncementNormalizer,
    prefix: []const u8,
    output: []const u8,
) ![]u8 {
    const normalized = try alloc.alloc(u8, prefix.len + output.len + 1);
    errdefer alloc.free(normalized);
    var write_index: usize = 0;
    try normalizeSemanticAnnouncementSlice(normalizer, normalized, &write_index, prefix);
    try normalizeSemanticAnnouncementSlice(normalizer, normalized, &write_index, output);
    return alloc.realloc(normalized, write_index);
}

fn normalizeSemanticAnnouncement(alloc: Allocator, input: []const u8) ![]u8 {
    var normalizer: AnnouncementNormalizer = .{};
    return normalizeSemanticAnnouncementParts(alloc, &normalizer, "", input);
}

fn normalizeSemanticAnnouncementJoined(
    alloc: Allocator,
    prefix: []const u8,
    output: []const u8,
) ![]u8 {
    var normalizer: AnnouncementNormalizer = .{};
    return normalizeSemanticAnnouncementParts(alloc, &normalizer, prefix, output);
}
/// Append only valid printable UTF-8 input to the bounded echo queue.
fn appendInputQueue(
    queue: []u8,
    queue_len: *usize,
    matched_len: *usize,
    complete: *bool,
    input: []const u8,
) bool {
    var appended = false;
    var read_index: usize = 0;
    while (read_index < input.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[read_index]) catch {
            read_index += 1;
            continue;
        };
        if (read_index + sequence_len > input.len) break;
        const sequence = input[read_index .. read_index + sequence_len];
        const codepoint = std.unicode.utf8Decode(sequence) catch {
            read_index += 1;
            continue;
        };
        read_index += sequence_len;
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) continue;
        if (sequence_len > queue.len) continue;

        while (queue_len.* + sequence_len > queue.len) {
            complete.* = false;
            matched_len.* = 0;
            const front_len = std.unicode.utf8ByteSequenceLength(queue[0]) catch 1;
            const remove_len = @min(front_len, queue_len.*);
            const remaining = queue_len.* - remove_len;
            std.mem.copyForwards(u8, queue[0..remaining], queue[remove_len..queue_len.*]);
            queue_len.* = remaining;
        }
        @memcpy(queue[queue_len.* .. queue_len.* + sequence_len], sequence);
        queue_len.* += sequence_len;
        appended = true;
    }
    return appended;
}

/// Suppress an echo only after the complete retained input is observed at a
/// terminal boundary. Partial increments advance a match cursor without
/// deleting the retained input, so an ambiguous suffix can never truncate real
/// output. A truncated queue disables suppression and favors extra speech.
pub const EchoOutput = struct {
    held_prefix: []const u8 = "",
    output: []const u8,
};

fn consumeEchoPrefix(
    queue: []u8,
    queue_len: *usize,
    matched_len: *usize,
    complete: *bool,
    output: []const u8,
) EchoOutput {
    if (!complete.*) {
        const held = queue[0..matched_len.*];
        queue_len.* = 0;
        matched_len.* = 0;
        complete.* = true;
        return .{ .held_prefix = held, .output = output };
    }
    const pending = queue[matched_len.*..queue_len.*];
    const compared = @min(pending.len, output.len);
    if (!std.mem.eql(u8, pending[0..compared], output[0..compared])) {
        const held = queue[0..matched_len.*];
        queue_len.* = 0;
        matched_len.* = 0;
        complete.* = true;
        return .{ .held_prefix = held, .output = output };
    }
    if (output.len <= pending.len) {
        matched_len.* += output.len;
        return .{ .output = output[0..0] };
    }
    const boundary = output[pending.len];
    if (!std.ascii.isWhitespace(boundary) and boundary >= 0x20 and boundary != 0x7f) {
        const held = queue[0..matched_len.*];
        queue_len.* = 0;
        matched_len.* = 0;
        complete.* = true;
        return .{ .held_prefix = held, .output = output };
    }
    queue_len.* = 0;
    matched_len.* = 0;
    complete.* = true;
    return .{ .output = std.mem.trimLeft(u8, output[pending.len..], " \t\r\n") };
}

test "terminal accessibility refresh and query policies" {
    try std.testing.expect(refreshDue(0, 1));
    try std.testing.expect(!refreshDue(100, 199));
    try std.testing.expect(refreshDue(100, 200));
    try std.testing.expectEqual(@as(UINT, 1), refreshDelay(100, 199));
    try std.testing.expectEqual(@as(UINT, 80), refreshDelay(100, 120));
    try std.testing.expect(!snapshotWasSlow(100, 199));
    try std.testing.expect(snapshotWasSlow(100, 200));
    try std.testing.expect(!queryRecentlyActive(0, 1));
    try std.testing.expect(queryRecentlyActive(100, 1_100));
    try std.testing.expect(!queryRecentlyActive(100, 1_101));
    try std.testing.expect(queryNeedsSynchronousRefresh(0, 1));
    try std.testing.expect(!queryNeedsSynchronousRefresh(100, 1_100));

    const idle = publishPolicy(false, false);
    try std.testing.expect(!idle.refresh_snapshot);
    try std.testing.expect(!idle.emit_events);
    const query_only = publishPolicy(false, true);
    try std.testing.expect(query_only.refresh_snapshot);
    try std.testing.expect(!query_only.emit_events);
    const subscribed = publishPolicy(true, false);
    try std.testing.expect(subscribed.refresh_snapshot);
    try std.testing.expect(subscribed.emit_events);

    // No listener or recent query is required after provider acquisition.
    try std.testing.expect(semanticOutputInterestPolicy(true, true, true));
    try std.testing.expect(!semanticOutputInterestPolicy(true, true, false));
    try std.testing.expect(!semanticOutputInterestPolicy(true, false, true));
    try std.testing.expect(!semanticOutputInterestPolicy(false, true, true));
}

test "terminal output announcements are readable bounded increments" {
    const announcement = try normalizeSemanticAnnouncement(
        std.testing.allocator,
        "hello\r\n\tworld  🚀 ",
    );
    defer std.testing.allocator.free(announcement);
    try std.testing.expectEqualStrings("hello world 🚀", announcement);
}

test "terminal output announcement normalization allocation failure becomes ordered omission" {
    var ctx: u8 = 0;
    const session = try TerminalAccessibilitySession.create(
        std.testing.allocator,
        TestOps.ops(&ctx),
        0,
        0,
    );
    defer session.deinit();

    session.recent_input[0] = 'x';
    session.recent_input_len = 1;
    session.recent_input_matched = 1;
    session.announcement_normalizer = .{
        .pending_space = true,
        .has_text = true,
    };
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const original_alloc = session.alloc;
    session.alloc = failing.allocator();
    session.mutex.lock();
    const candidate = session.normalizeSemanticOutputLocked("", "output", true);
    session.mutex.unlock();
    session.alloc = original_alloc;

    try std.testing.expect(candidate == null);
    try std.testing.expectEqual(@as(usize, 0), session.recent_input_len);
    try std.testing.expect(!session.announcement_normalizer.pending_space);
    try std.testing.expect(!session.announcement_normalizer.has_text);
    const omission = (try session.takePendingAnnouncement()).?;
    defer std.testing.allocator.free(omission);
    try std.testing.expectEqualStrings(omitted_output_notice, omission);
}

test "unchanged terminal refresh emit handles every allocation failure" {
    const run = struct {
        fn testRefresh(alloc: Allocator) !void {
            var ctx: u8 = 0;
            const session = try TerminalAccessibilitySession.create(
                alloc,
                TestOps.ops(&ctx),
                0,
                0,
            );
            defer session.deinit();

            session.enqueuePendingAnnouncements("pending");
            const result = try session.refresh(.emit, false);
            defer if (result.announcement) |announcement| alloc.free(announcement);
            try std.testing.expectEqual(Change.unchanged, result.change);
            try std.testing.expectEqualStrings("pending", result.announcement.?);
        }
    }.testRefresh;

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        run,
        .{},
    );
}

test "terminal output suppression normalizes per-key input and Enter" {
    var queue: [64]u8 = undefined;
    var queue_len: usize = 0;
    var matched_len: usize = 0;
    var complete = true;
    for ([_][]const u8{ "e", "c", "h", "o", " ", "f", "o", "o", "\r" }) |key| {
        _ = appendInputQueue(&queue, &queue_len, &matched_len, &complete, key);
    }
    try std.testing.expectEqualStrings("echo foo", queue[0..queue_len]);

    try std.testing.expectEqualStrings(
        "",
        consumeEchoPrefix(&queue, &queue_len, &matched_len, &complete, "echo ").output,
    );
    try std.testing.expectEqualStrings(
        "",
        consumeEchoPrefix(&queue, &queue_len, &matched_len, &complete, "foo").output,
    );
    const raw_spoken = consumeEchoPrefix(
        &queue,
        &queue_len,
        &matched_len,
        &complete,
        "\r\nresult\r\n",
    );
    const announcement = try normalizeSemanticAnnouncementJoined(
        std.testing.allocator,
        raw_spoken.held_prefix,
        raw_spoken.output,
    );
    defer std.testing.allocator.free(announcement);
    try std.testing.expectEqualStrings("result", announcement);
    try std.testing.expectEqual(@as(usize, 0), queue_len);
}

test "long split input echo keeps the complete output marker" {
    const command =
        "cmd.exe /d /c \"echo whi0123456789abcdef0123456789abcdef^" ++
        "fedcba9876543210fedcba9876543210\"";
    const marker =
        "whi0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210";
    var queue: [256]u8 = undefined;
    var queue_len: usize = 0;
    var matched_len: usize = 0;
    var complete = true;
    try std.testing.expect(appendInputQueue(
        &queue,
        &queue_len,
        &matched_len,
        &complete,
        command,
    ));
    try std.testing.expect(command.len > 64);
    try std.testing.expect(complete);
    try std.testing.expectEqualStrings(
        "",
        consumeEchoPrefix(
            &queue,
            &queue_len,
            &matched_len,
            &complete,
            command[0..47],
        ).output,
    );
    try std.testing.expectEqualStrings(
        "",
        consumeEchoPrefix(
            &queue,
            &queue_len,
            &matched_len,
            &complete,
            command[47..],
        ).output,
    );
    const raw_spoken = consumeEchoPrefix(
        &queue,
        &queue_len,
        &matched_len,
        &complete,
        "\r\n" ++ marker ++ "\r\n",
    );
    const announcement = try normalizeSemanticAnnouncementJoined(
        std.testing.allocator,
        raw_spoken.held_prefix,
        raw_spoken.output,
    );
    defer std.testing.allocator.free(announcement);
    try std.testing.expectEqualStrings(marker, announcement);
    try std.testing.expect(std.mem.indexOf(u8, announcement, command) == null);
}

test "truncated input queue never truncates real output" {
    var queue: [8]u8 = undefined;
    var queue_len: usize = 0;
    var matched_len: usize = 0;
    var complete = true;
    _ = appendInputQueue(
        &queue,
        &queue_len,
        &matched_len,
        &complete,
        "long-command",
    );
    try std.testing.expect(!complete);
    const output = "command\r\nresult";
    try std.testing.expectEqualStrings(
        output,
        consumeEchoPrefix(
            &queue,
            &queue_len,
            &matched_len,
            &complete,
            output,
        ).output,
    );
}

test "ambiguous partial echo mismatch preserves held output" {
    var queue: [32]u8 = undefined;
    var queue_len: usize = 0;
    var matched_len: usize = 0;
    var complete = true;
    _ = appendInputQueue(
        &queue,
        &queue_len,
        &matched_len,
        &complete,
        "echo foo",
    );
    const ambiguous = consumeEchoPrefix(
        &queue,
        &queue_len,
        &matched_len,
        &complete,
        "e",
    );
    try std.testing.expectEqualStrings("", ambiguous.output);
    const mismatch = consumeEchoPrefix(
        &queue,
        &queue_len,
        &matched_len,
        &complete,
        "rror",
    );
    const spoken = try normalizeSemanticAnnouncementJoined(
        std.testing.allocator,
        mismatch.held_prefix,
        mismatch.output,
    );
    defer std.testing.allocator.free(spoken);
    try std.testing.expectEqualStrings("error", spoken);
}

test "terminal output queue chunks a multi-kilobyte burst without losing tail" {
    var session: TerminalAccessibilitySession = undefined;
    session.alloc = std.testing.allocator;
    session.pending_announcement_head = 0;
    session.pending_announcement_count = 0;
    session.pending_output_omitted = false;
    const burst = "a" ** 2_400 ++ " UNIQUE_TAIL";
    session.enqueuePendingAnnouncements(burst);
    try std.testing.expectEqual(@as(usize, 3), session.pending_announcement_count);
    const tail_index = (session.pending_announcement_head + 2) % max_pending_announcements;
    const tail = session.pending_announcements[tail_index][0..session.pending_announcement_lengths[tail_index]];
    try std.testing.expect(std.mem.endsWith(u8, tail, "UNIQUE_TAIL"));
    try std.testing.expect(!session.pending_output_omitted);
}

test "snapshot refresh never consumes or clears queued terminal output" {
    var ctx: u8 = 0;
    const session = try TerminalAccessibilitySession.create(
        std.testing.allocator,
        TestOps.ops(&ctx),
        0,
        0,
    );
    defer session.deinit();
    session.enqueuePendingAnnouncements("background output before provider reacquisition");
    const before_count = session.pending_announcement_count;
    const before_head = session.pending_announcement_head;

    const result = try session.refresh(.discard, false);
    try std.testing.expect(result.announcement == null);
    try std.testing.expect(result.announcement_pending);
    try std.testing.expectEqual(before_count, session.pending_announcement_count);
    try std.testing.expectEqual(before_head, session.pending_announcement_head);
    const queued = session.pending_announcements[before_head][0..session.pending_announcement_lengths[before_head]];
    try std.testing.expectEqualStrings("background output before provider reacquisition", queued);
}

test "terminal focus loss cancels speech and echo backlog" {
    var ctx: u8 = 0;
    const session = try TerminalAccessibilitySession.create(
        std.testing.allocator,
        TestOps.ops(&ctx),
        0,
        0,
    );
    defer session.deinit();
    session.enqueuePendingAnnouncements("stale output");
    session.noteInput("typed input");
    session.refresh_timer_active = true;

    session.focusChanged(false);

    try std.testing.expect(!session.refresh_timer_active);
    try std.testing.expectEqual(@as(usize, 0), session.pending_announcement_count);
    try std.testing.expect(!session.pending_output_omitted);
    try std.testing.expectEqual(@as(usize, 0), session.recent_input_len);
}

test "terminal name cache refreshes without an event listener" {
    var ctx: MutableTestOps.Context = .{
        .focused = true,
        .text = "",
        .name = "Terminal: old",
    };
    const session = try TerminalAccessibilitySession.create(
        std.testing.allocator,
        MutableTestOps.ops(&ctx),
        0,
        0,
    );
    defer session.deinit();

    ctx.name = "Terminal: current";
    session.nameChanged();
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Terminal: current",
        TerminalAccessibilitySession.providerName(@ptrCast(session), &buf),
    );
}

test "terminal name cache copies non-aliasing initial fallback" {
    var ctx: MutableTestOps.Context = .{
        .focused = true,
        .text = "",
        .name = "Terminal",
        .return_name_without_copy = true,
    };
    const session = try TerminalAccessibilitySession.create(
        std.testing.allocator,
        MutableTestOps.ops(&ctx),
        0,
        0,
    );
    defer session.deinit();

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Terminal",
        TerminalAccessibilitySession.providerName(@ptrCast(session), &buf),
    );
}

test "terminal name cache replaces normal name with non-aliasing fallback" {
    var ctx: MutableTestOps.Context = .{
        .focused = true,
        .text = "",
        .name = "Terminal: stale long title",
    };
    const session = try TerminalAccessibilitySession.create(
        std.testing.allocator,
        MutableTestOps.ops(&ctx),
        0,
        0,
    );
    defer session.deinit();

    ctx.name = "Terminal";
    ctx.return_name_without_copy = true;
    session.nameChanged();

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Terminal",
        TerminalAccessibilitySession.providerName(@ptrCast(session), &buf),
    );
}

test "terminal name cache caps non-aliasing names to capacity" {
    const long_name = "n" ** 300;
    var ctx: MutableTestOps.Context = .{
        .focused = true,
        .text = "",
        .name = long_name,
        .return_name_without_copy = true,
    };
    const session = try TerminalAccessibilitySession.create(
        std.testing.allocator,
        MutableTestOps.ops(&ctx),
        0,
        0,
    );
    defer session.deinit();

    var buf: [512]u8 = undefined;
    const name = TerminalAccessibilitySession.providerName(@ptrCast(session), &buf);
    try std.testing.expectEqual(@as(usize, 256), name.len);
    try std.testing.expectEqualStrings(long_name[0..256], name);
}

test "inactive terminal output snapshot is fresh on later focus without speech" {
    var ctx: MutableTestOps.Context = .{
        .focused = false,
        .text = "initial",
    };
    const session = try TerminalAccessibilitySession.create(
        std.testing.allocator,
        MutableTestOps.ops(&ctx),
        0,
        0,
    );
    defer session.deinit();

    ctx.text = "background output";
    const background = try session.refresh(.discard, false);
    try std.testing.expectEqual(Change.text_and_caret, background.change);
    try std.testing.expect(background.announcement == null);
    try std.testing.expectEqualStrings("background output", session.cached_text);
    try std.testing.expectEqual(@as(usize, 0), session.pending_announcement_count);

    ctx.text = "background output UNIQUE_INACTIVE_MARKER";
    const focus_refresh = try session.refresh(.discard, false);
    try std.testing.expectEqual(Change.text_and_caret, focus_refresh.change);
    try std.testing.expect(focus_refresh.announcement == null);
    try std.testing.expectEqual(@as(usize, 0), session.pending_announcement_count);
    ctx.focused = true;
    session.focusChanged(true);
    const first_text = try TerminalAccessibilitySession.providerValue(
        @ptrCast(session),
        std.testing.allocator,
    );
    defer std.testing.allocator.free(first_text);
    try std.testing.expectEqualStrings(
        "background output UNIQUE_INACTIVE_MARKER",
        first_text,
    );
    try std.testing.expectEqual(@as(usize, 0), session.pending_announcement_count);
}

test "bounded terminal output queue emits explicit omission after retained chunks" {
    var session: TerminalAccessibilitySession = undefined;
    session.alloc = std.testing.allocator;
    session.pending_announcement_head = 0;
    session.pending_announcement_count = 0;
    session.pending_output_omitted = false;
    session.enqueuePendingAnnouncements("z" ** (max_announcement_bytes * (max_pending_announcements + 2)));
    try std.testing.expectEqual(max_pending_announcements, session.pending_announcement_count);
    try std.testing.expect(session.pending_output_omitted);

    for (0..max_pending_announcements) |_| {
        const chunk = (try session.takePendingAnnouncement()).?;
        defer std.testing.allocator.free(chunk);
        try std.testing.expectEqual(max_announcement_bytes, chunk.len);
        try std.testing.expect(std.mem.allEqual(u8, chunk, 'z'));
    }
    const omission = (try session.takePendingAnnouncement()).?;
    defer std.testing.allocator.free(omission);
    try std.testing.expectEqualStrings(omitted_output_notice, omission);
    try std.testing.expect((try session.takePendingAnnouncement()) == null);
}

test "terminal output omission remains ordered before newer output" {
    var session: TerminalAccessibilitySession = undefined;
    session.alloc = std.testing.allocator;
    session.pending_announcement_head = 0;
    session.pending_announcement_count = 0;
    session.pending_output_omitted = false;
    session.pending_announcement_omitted = [_]bool{false} ** max_pending_announcements;

    const old = [_][]const u8{ "old-0", "old-1", "old-2", "old-3", "old-4", "old-5", "old-6", "old-7" };
    for (old) |announcement| session.enqueuePendingAnnouncements(announcement);
    session.enqueuePendingAnnouncements("dropped-before-barrier");

    const first = (try session.takePendingAnnouncement()).?;
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("old-0", first);
    const second = (try session.takePendingAnnouncement()).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("old-1", second);
    session.enqueuePendingAnnouncements("new-after-barrier");

    var drained: std.ArrayList(u8) = .empty;
    defer drained.deinit(std.testing.allocator);
    while (try session.takePendingAnnouncement()) |announcement| {
        defer std.testing.allocator.free(announcement);
        if (drained.items.len != 0) try drained.append(std.testing.allocator, '|');
        try drained.appendSlice(std.testing.allocator, announcement);
    }
    try std.testing.expectEqualStrings(
        "old-2|old-3|old-4|old-5|old-6|old-7|terminal output omitted|new-after-barrier",
        drained.items,
    );
}

test "terminal output stream survives more than six hundred lines in order" {
    var bytes: [7_000]u8 = undefined;
    var stream = std.io.fixedBufferStream(&bytes);
    for (0..650) |index| try stream.writer().print("line-{d:0>3}\n", .{index});
    const readable = try normalizeSemanticAnnouncement(std.testing.allocator, stream.getWritten());
    defer std.testing.allocator.free(readable);

    var session: TerminalAccessibilitySession = undefined;
    session.alloc = std.testing.allocator;
    session.pending_announcement_head = 0;
    session.pending_announcement_count = 0;
    session.pending_output_omitted = false;
    session.enqueuePendingAnnouncements(readable);
    var drained: std.ArrayList(u8) = .empty;
    defer drained.deinit(std.testing.allocator);
    while (try session.takePendingAnnouncement()) |announcement| {
        defer std.testing.allocator.free(announcement);
        try drained.appendSlice(std.testing.allocator, announcement);
    }
    try std.testing.expectEqualStrings(readable, drained.items);
    try std.testing.expect(!session.pending_output_omitted);
}
