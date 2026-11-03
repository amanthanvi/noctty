//! Desktop notifications: what noctty tells the user through Windows toasts,
//! when a toast leaves Action Center, and what a click on one brings forward.
//!
//! A toast from a pane is tagged by the pane and grouped by this process, so
//! the pane's newer toast replaces its older one. It leaves Action Center
//! once the user has seen the pane's tab, or once the pane is in no live tab
//! (closed, or waiting in undo or redo history), and every toast of the
//! process leaves at exit. A removal names the tag and the group, never the
//! AUMID alone and never `Clear`: other noctty processes share the AUMID.
//!
//! It also holds the cold start's wait for its click (`ColdToastCapture`,
//! `pumpUntilColdToastActivation`): what a `-ToastActivated` start receives
//! before the App's channel exists, which the App then hands to `click`.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Target = @import("../action.zig").Target;
const c = @import("consts.zig");
const sys = @import("sys.zig");
const win32_program_status = @import("../win32_program_status.zig");
const toast_activation = @import("../win32_toast_activation.zig");
const win32_toast_activator = @import("../win32_toast_activator.zig");
const win32_toast_winrt = @import("../win32_toast_winrt.zig");
const win32_types = @import("../win32_types.zig");

const log = std.log.scoped(.win32);

const ToastRequest = win32_toast_winrt.ToastRequest;

/// Where a toast goes: WinRT in the product (`ToastSink.winrt`), a
/// recorder in tests (`testing.Recorder`), so no test can reach Action
/// Center. Every call is cross-process COM and can pump messages.
pub const ToastSink = struct {
    ctx: *anyopaque,
    show: *const fn (ctx: *anyopaque, request: ToastRequest) anyerror!void,
    /// Take the toast tagged `tag` in `group` out of Action Center.
    remove_tag: *const fn (ctx: *anyopaque, tag: []const u8, group: []const u8) anyerror!void,
    /// Take every toast in `group` out of Action Center.
    remove_group: *const fn (ctx: *anyopaque, group: []const u8) anyerror!void,

    pub fn winrt(toast: *win32_toast_winrt.WinrtToast) ToastSink {
        return .{ .ctx = toast, .show = showWinrt, .remove_tag = removeTagWinrt, .remove_group = removeGroupWinrt };
    }

    fn showWinrt(ctx: *anyopaque, request: ToastRequest) anyerror!void {
        const toast: *win32_toast_winrt.WinrtToast = @ptrCast(@alignCast(ctx));
        try toast.show(request, .info);
    }

    fn removeTagWinrt(ctx: *anyopaque, tag: []const u8, group: []const u8) anyerror!void {
        const toast: *win32_toast_winrt.WinrtToast = @ptrCast(@alignCast(ctx));
        try toast.removeGroupedTag(tag, group);
    }

    fn removeGroupWinrt(ctx: *anyopaque, group: []const u8) anyerror!void {
        const toast: *win32_toast_winrt.WinrtToast = @ptrCast(@alignCast(ctx));
        try toast.removeGroup(group);
    }
};

/// Who a notification is from.
pub const From = union(enum) {
    /// noctty itself (a config reload, a Settings save): no tab line, no
    /// launch and no tag; untitled, it is titled "noctty".
    app,
    /// A pane, by core surface id, never a pointer: the pane may be gone
    /// by the time its toast is removed. A program's notification (OSC 9,
    /// OSC 777) and one the core shows about the pane (a clipboard-copy
    /// notice, titled "noctty") arrive alike and are not told apart, not
    /// by the title either: a program can send "noctty" too.
    pane: u64,

    pub fn of(target: Target) From {
        return switch (target) {
            .app => .app,
            .surface => |core| .{ .pane = core.id },
        };
    }
};

/// The window a tab is in, as its toast names it.
pub const Window = union(enum) {
    quick_terminal,
    /// `number` counts the open windows other than the quick terminal, in
    /// order, and is null for a window that is not registered.
    ordinary: struct { number: ?u32, open: u32 },
};

/// What the App knows of a pane (`Panes.find`).
pub const Pane = struct {
    /// The pane's window (`Surface.host_id`), kept outside a live tab too.
    window_id: u32,
    /// null: the pane is in no live tab (closing, or waiting in undo or
    /// redo history).
    tab: ?Tab,

    pub const Tab = struct {
        id: u32,
        /// From 0.
        index: usize,
        /// What the user knows the tab by: its focused pane's title, or
        /// "noctty", as it is (`show` sanitizes it).
        name: []const u8,
        window: Window,
    };
};

/// What a click brings forward (`Panes.present`).
pub const Present = union(enum) {
    pane: u64,
    /// The tab's focused pane.
    tab: struct { window: u32, tab: u32 },
    /// The window's active pane.
    window: u32,
    /// The first window's active pane.
    primary,
};

/// What the module asks of the App (a port). Adapters: the App's
/// (`App.notificationPanes`), `testing.FakePanes` and `none`. `find` and
/// `wake` call nothing back. `present` activates a window, whose activation
/// and focus handling call `seen`, and `banner` changes a window: the module
/// keeps nothing of its list across either.
pub const Panes = struct {
    ctx: *anyopaque,
    /// null: no pane has this id. The strings are borrowed until the next
    /// call on this port.
    find: *const fn (ctx: *anyopaque, pane: u64) ?Pane,
    /// Bring `which` forward; false: there is no such pane, tab or window.
    present: *const fn (ctx: *anyopaque, which: Present) bool,
    /// An info banner in the window of `from` (`.app`: the primary window);
    /// false: no window can hold it.
    banner: *const fn (ctx: *anyopaque, from: From, text: []const u8) bool,
    /// Post one `WM_WINHOSTTY_TOAST_REMOVALS`, whose handler calls `flush`;
    /// false: no message window.
    wake: *const fn (ctx: *anyopaque) bool,

    /// Finds nothing, presents nothing, holds no banner and never wakes.
    pub const none: Panes = .{ .ctx = undefined, .find = findNone, .present = presentNone, .banner = bannerNone, .wake = wakeNone };

    fn findNone(_: *anyopaque, _: u64) ?Pane {
        return null;
    }

    fn presentNone(_: *anyopaque, _: Present) bool {
        return false;
    }

    fn bannerNone(_: *anyopaque, _: From, _: []const u8) bool {
        return false;
    }

    fn wakeNone(_: *anyopaque) bool {
        return false;
    }
};

/// What reaches `Notifications.click`.
pub const Click = union(enum) {
    /// A click from the toast's popup handler or the COM activator (through
    /// the App's message window), or one a cold start forwarded: a repeat
    /// of a click inside `RepeatFilter.window_ms` is dropped.
    target: toast_activation.ActivationTarget,
    /// The click this process was started for (a `wgh://activate?...`
    /// argument, or what a cold `-ToastActivated` start received): kept
    /// for the first window, unfiltered.
    start: toast_activation.ActivationTarget,
    /// A new window's first pane exists: a kept click is presented now.
    window_opened,
};

pub const Outcome = enum {
    done,
    /// Nothing could be presented and the click is kept: the caller decides
    /// whether to open a window for it.
    needs_window,
};

pub const Notifications = struct {
    alloc: Allocator,
    sink: ?ToastSink,
    panes: Panes,
    /// The panes whose toast may be in Action Center, in the order their
    /// toasts were shown.
    tracked: std.ArrayListUnmanaged(Entry) = .empty,
    /// `Panes.wake` posted, and its `flush` has not run yet.
    wake_posted: bool = false,
    /// This process showed a tagged toast, so its group may hold toasts at
    /// exit.
    group_used: bool = false,
    /// Drops the second delivery of one click (popup handler and COM).
    click_filter: toast_activation.RepeatFilter = .{},
    /// The click waiting for a window to present it; the newest wins.
    kept: ?toast_activation.ActivationTarget = null,

    const Entry = struct {
        pane: u64,
        state: State,
    };

    const State = union(enum) {
        /// In Action Center: removed at a flush once its pane is in no live
        /// tab.
        shown,
        /// Removed at the next flush.
        seen,
        /// In the sink. What the entry was before is on that show's stack;
        /// `seen` says the tab was seen meanwhile, which is a seen of the
        /// older toast: the newer one replaces it if Windows takes it.
        showing: struct { seen: bool = false },
    };

    /// No sink and `Panes.none`: every notification is a log line, and
    /// nothing is tracked.
    pub const disabled: Notifications = .{ .alloc = std.heap.page_allocator, .sink = null, .panes = .none };

    /// `sink` null sends every notification to the banner fallback.
    pub fn init(alloc: Allocator, sink: ?ToastSink, panes: Panes) Notifications {
        return .{ .alloc = alloc, .sink = sink, .panes = panes };
    }

    /// At exit, after the last window is gone and before the sink's
    /// notifier is released: take this process's toasts out of Action
    /// Center, all at once by its group, if it showed a tagged one.
    pub fn deinit(self: *Notifications) void {
        self.tracked.deinit(self.alloc);
        self.tracked = .empty;
        self.wake_posted = false;
        if (!self.group_used) return;
        self.group_used = false;
        const sink = self.sink orelse return;
        var group_buf: [toast_group_max]u8 = undefined;
        sink.remove_group(sink.ctx, toastGroup(&group_buf)) catch |err| {
            log.warn("toast group removal at exit failed err={}", .{err});
        };
    }

    /// Show a toast; when Windows takes none, an info banner in the
    /// sender's window, and failing that a log line. A pane's toast names
    /// its tab, is titled by the tab when untitled (OSC 9 has no title), as
    /// Windows Terminal does, focuses the pane when clicked and replaces the
    /// pane's older toast. The sink can pump messages that close panes,
    /// tabs and windows: a caller must not use a pane, window or tab index
    /// it read before the call. `title` and `body` are borrowed for the
    /// call only.
    pub fn show(self: *Notifications, from: From, title: []const u8, body: []const u8) void {
        const id = switch (from) {
            .app => return self.showUntracked(from, title, body),
            .pane => |id| id,
        };
        const pane = self.panes.find(self.panes.ctx, id) orelse return self.showUntracked(from, title, body);

        // The pane's strings are copied before anything else is called.
        var name_buf: [tab_title_max + "\u{2026}".len]u8 = undefined;
        var name: std.Io.Writer = .fixed(&name_buf);
        var line_buf: [160]u8 = undefined;
        var line: std.Io.Writer = .fixed(&line_buf);
        const attribution: ?[]const u8 = if (pane.tab) |tab| line: {
            // Both fit: the line is at most 38 bytes before the name.
            writeTabLine(&line, tab.index, tab.window, tab.name) catch unreachable;
            if (title.len == 0) win32_program_status.writeSanitized(&name, tab.name, tab_title_max) catch unreachable;
            break :line line.buffered();
        } else null;

        const launch = buildLaunch(self.alloc, id, if (pane.tab) |tab| tab.id else null, pane.window_id) catch {
            log.warn("toast not shown: out of memory", .{});
            return;
        };
        defer self.alloc.free(launch);
        var tag_buf: [16]u8 = undefined;
        var group_buf: [toast_group_max]u8 = undefined;
        const request: ToastRequest = .{
            .title = if (title.len > 0) title else name.buffered(),
            .body = body,
            .attribution = attribution,
            .launch = launch,
            .tag = toastTag(&tag_buf, id),
            .group = toastGroup(&group_buf),
        };

        const sink = self.sink orelse return self.fallBack(from, title, body, attribution);
        // A toast it cannot track could not leave when its tab is seen or its
        // pane closes, so it is not shown.
        const prior = self.beginShow(id) catch |err| {
            log.warn("toast not shown: cannot track it err={}", .{err});
            return;
        };
        const shown = toSink(sink, request);
        self.endShow(id, prior, shown);
        if (!shown) self.fallBack(from, title, body, attribution);
    }

    /// The pane's tab was seen: its toast, if it may still be in Action
    /// Center, leaves at the next flush. Calls nothing in Windows but
    /// `PostMessage`, so it is safe inside window activation and focus
    /// handling.
    pub fn seen(self: *Notifications, pane: u64) void {
        const i = self.indexOf(pane) orelse return;
        switch (self.tracked.items[i].state) {
            .shown => self.tracked.items[i].state = .seen,
            .seen => {},
            .showing => |*showing| {
                showing.seen = true;
                return;
            },
        }
        self.wake();
    }

    /// A pane closed, or went into or came out of undo or redo history. Its
    /// toast leaves at the next flush if the pane is then in no live tab.
    /// Reads nothing from the pane and calls nothing in Windows but
    /// `PostMessage`, so it is safe in a close, also after the pane's core
    /// is gone.
    pub fn panesChanged(self: *Notifications) void {
        if (self.tracked.items.len == 0) return;
        self.wake();
    }

    /// Take the toasts that are seen or whose pane is in no live tab out of
    /// Action Center. Only from the posted `WM_WINHOSTTY_TOAST_REMOVALS`:
    /// each call can pump messages, so each entry leaves the list before its
    /// call, and a toast shown meanwhile for a pane still listed stays.
    pub fn flush(self: *Notifications) void {
        self.wake_posted = false;
        const sink = self.sink orelse return;
        var group_buf: [toast_group_max]u8 = undefined;
        const group = toastGroup(&group_buf);
        while (self.takeRemovable()) |pane| {
            var tag_buf: [16]u8 = undefined;
            sink.remove_tag(sink.ctx, toastTag(&tag_buf, pane), group) catch |err| {
                log.warn("toast removal failed err={}", .{err});
            };
        }
    }

    /// A click on a toast, or a window it waits for. It brings forward the
    /// pane it names, else that pane's tab, else its window, else the
    /// primary window. With nothing to bring forward (`initial-window =
    /// false`, or the last window closed under
    /// `quit-after-last-window-closed = false`) it is kept for the next
    /// window, and `.needs_window` asks the caller for one. Presenting
    /// activates a window, so this never runs inside WM_ACTIVATE or a focus
    /// callback.
    pub fn click(self: *Notifications, what: Click) Outcome {
        switch (what) {
            .target => |target| {
                // The popup's handler and the COM activator can both report
                // one popup click, and a cold start forwards one this
                // process may have had already.
                if (!self.click_filter.admit(target, std.time.milliTimestamp())) return .done;
                if (self.bringForward(target)) return .done;
                self.kept = target;
                return .needs_window;
            },
            .start => |target| self.kept = target,
            .window_opened => if (self.kept) |target| {
                if (self.bringForward(target)) self.kept = null;
            },
        }
        return .done;
    }

    fn bringForward(self: *Notifications, target: toast_activation.ActivationTarget) bool {
        // Exhaustive on purpose: a new action must be handled here.
        if (target.action) |action| switch (action) {
            .focus => {},
        };
        const panes = self.panes;
        // Ids are this process's only when the toast is: a click on another
        // noctty's toast (COM hands it to whichever process registered the
        // activator, or to a new one after that process ended) must not pick
        // a window or tab that happens to share a number here.
        if (target.pid != sys.GetCurrentProcessId()) return panes.present(panes.ctx, .primary);
        if (target.surface_id) |pane| {
            if (panes.present(panes.ctx, .{ .pane = pane })) return true;
        }
        if (target.window_id) |window| {
            // The toast's tab before its window's active one: the pane of an
            // old toast can be gone from a tab that is still there.
            if (target.tab_id) |tab| {
                if (panes.present(panes.ctx, .{ .tab = .{ .window = window, .tab = tab } })) return true;
            }
            if (panes.present(panes.ctx, .{ .window = window })) return true;
        }
        return panes.present(panes.ctx, .primary);
    }

    fn takeRemovable(self: *Notifications) ?u64 {
        for (self.tracked.items, 0..) |entry, i| {
            const gone = switch (entry.state) {
                .seen => true,
                .shown => !self.reachable(entry.pane),
                .showing => false,
            };
            if (!gone) continue;
            _ = self.tracked.orderedRemove(i);
            return entry.pane;
        }
        return null;
    }

    fn reachable(self: *Notifications, pane: u64) bool {
        const found = self.panes.find(self.panes.ctx, pane) orelse return false;
        return found.tab != null;
    }

    fn wake(self: *Notifications) void {
        if (self.wake_posted) return;
        self.wake_posted = self.panes.wake(self.panes.ctx);
    }

    fn indexOf(self: *const Notifications, pane: u64) ?usize {
        for (self.tracked.items, 0..) |entry, i| {
            if (entry.pane == pane) return i;
        }
        return null;
    }

    /// Mark the pane's entry as in the sink, last in show order, and return
    /// what it was (null: no entry).
    fn beginShow(self: *Notifications, pane: u64) Allocator.Error!?State {
        const entry: Entry = .{ .pane = pane, .state = .{ .showing = .{} } };
        if (self.indexOf(pane)) |i| {
            const prior = self.tracked.orderedRemove(i).state;
            self.tracked.appendAssumeCapacity(entry);
            return prior;
        }
        try self.tracked.append(self.alloc, entry);
        return null;
    }

    /// The show is back from the sink, which can have pumped messages that
    /// closed the pane or took it out of its tab, so the pane is found
    /// again. A show for the same pane inside this one decided the entry,
    /// unless Windows refused it, which put this show's state back. A flush
    /// meanwhile can have taken what the inner show decided; this show's
    /// toast, which Windows may have filed after that removal, is then the
    /// pane's again, so it is tracked anew (removing a toast that is already
    /// gone is harmless).
    fn endShow(self: *Notifications, pane: u64, prior: ?State, shown: bool) void {
        if (shown) self.group_used = true;
        const reach = self.reachable(pane);
        const i = self.indexOf(pane) orelse {
            if (!shown) return;
            const state: State = if (reach) .shown else .seen;
            self.tracked.append(self.alloc, .{ .pane = pane, .state = state }) catch |err| {
                log.warn("toast not tracked after a nested show err={}", .{err});
                return;
            };
            if (state == .seen) self.wake();
            return;
        };
        const showing = switch (self.tracked.items[i].state) {
            .showing => |showing| showing,
            .shown, .seen => return,
        };
        const state: State = if (shown)
            (if (reach) .shown else .seen)
        else if (prior) |older| switch (older) {
            // Windows refused the newer toast, so the older one is still in
            // Action Center, with whatever happened to it meanwhile.
            .shown => if (showing.seen or !reach) .seen else .shown,
            .seen => .seen,
            .showing => |outer| .{ .showing = .{ .seen = outer.seen or showing.seen } },
        } else {
            _ = self.tracked.orderedRemove(i);
            return;
        };
        self.tracked.items[i].state = state;
        if (state == .seen) self.wake();
    }

    /// An app's toast, or one from a pane no window has: no tag, launch or
    /// tab line, and nothing to remove.
    fn showUntracked(self: *Notifications, from: From, title: []const u8, body: []const u8) void {
        if (self.sink) |sink| if (toSink(sink, .{ .title = title, .body = body })) return;
        self.fallBack(from, title, body, null);
    }

    /// Whether Windows took the toast. On success there is no banner:
    /// showing both would tell the user twice. A show error (notifications
    /// turned off for noctty or for the user, the runtime unavailable, XML
    /// rejected) falls back to the banner. Under Focus Assist (Do not
    /// disturb) Windows may instead accept the toast and file it in Action
    /// Center without a popup, and then no banner appears; which of the two
    /// it does has not been measured for noctty.
    fn toSink(sink: ToastSink, request: ToastRequest) bool {
        var shown = request;
        if (shown.title.len == 0) shown.title = "noctty";
        sink.show(sink.ctx, shown) catch |err| {
            // test/windows/interactive-win11-command-finish.ps1 matches
            // this line's opening words; keep them.
            std.log.warn("winrt toast show failed err={}; falling back to banner", .{err});
            return false;
        };
        return true;
    }

    /// What the toast would have said, composed from the title the
    /// notification arrived with (a toast titled by its tab names the tab
    /// in its line already): a banner in the sender's window, else a log
    /// line.
    fn fallBack(self: *Notifications, from: From, title: []const u8, body: []const u8, attribution: ?[]const u8) void {
        var message: std.Io.Writer.Allocating = .init(self.alloc);
        defer message.deinit();
        composeFallback(&message.writer, title, body, attribution) catch {
            log.warn("notification not shown: out of memory", .{});
            return;
        };
        if (self.panes.banner(self.panes.ctx, from, message.written())) return;
        // The composed message, so one with an empty body (a Settings save,
        // whose title carries it) still says something.
        const caption = if (fallbackTitled(title)) title else "noctty";
        std.log.info("info notification (no visible target): {s} — {s}", .{ caption, message.written() });
    }
};

/// Receives the first `Activate` of a cold `-ToastActivated` start, before
/// the App channel exists. `Activate` runs on this thread, inside the wait's
/// message pump.
pub const ColdToastCapture = struct {
    received: bool = false,
    activation: toast_activation.ActivationTarget = .{},

    pub fn sink(self: *ColdToastCapture) win32_toast_activator.Sink {
        return .{ .ctx = self, .deliver = deliver };
    }

    fn deliver(ctx: *anyopaque, launch: []const u8) void {
        const self: *ColdToastCapture = @ptrCast(@alignCast(ctx));
        if (self.received) return;
        self.received = true;
        self.activation = toast_activation.parseLaunchArg(launch) catch .{};
    }
};

/// Dispatch this thread's messages until `capture` has its call or
/// `timeout_ms` has passed, and say whether the call came. COM hands an
/// incoming call to this STA as a message, so the dispatch is what runs
/// `Activate`. The deadline is the wait's own, with no timer that could fail
/// to arm, and a quit met on the way is put back for the main loop.
pub fn pumpUntilColdToastActivation(capture: *const ColdToastCapture, timeout_ms: u32) bool {
    const deadline = sys.GetTickCount64() + timeout_ms;
    var msg: sys.MSG = undefined;
    while (!capture.received) {
        while (sys.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) {
                sys.PostQuitMessage(@bitCast(@as(u32, @truncate(msg.wParam))));
                return capture.received;
            }
            _ = sys.TranslateMessage(&msg);
            _ = sys.DispatchMessageW(&msg);
            if (capture.received) return true;
        }
        const now = sys.GetTickCount64();
        if (now >= deadline) break;
        const remaining: win32_types.DWORD = @intCast(deadline - now);
        if (sys.MsgWaitForMultipleObjectsEx(0, null, remaining, c.QS_ALLINPUT, c.MWMO_INPUTAVAILABLE) == c.WAIT_FAILED) break;
    }
    return capture.received;
}

/// A pane's toast tag: its core surface id, 16 hex digits. One tag per pane,
/// so a newer toast from the pane replaces its older one in Action Center.
fn toastTag(buf: *[16]u8, surface_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{surface_id}) catch unreachable;
}

/// This process's toast group, `noctty-<pid>`: other noctty processes share
/// the AUMID, so everything this process removes at once is named by it.
fn toastGroup(buf: *[toast_group_max]u8) []const u8 {
    return std.fmt.bufPrint(buf, "noctty-{d}", .{sys.GetCurrentProcessId()}) catch unreachable;
}

const toast_group_max = "noctty-".len + std.fmt.count("{d}", .{std.math.maxInt(u32)});

/// The launch string a click on a pane's toast brings back: the pane, its
/// tab (null in no tab), its window and this process.
fn buildLaunch(alloc: Allocator, pane: u64, tab_id: ?u32, window_id: u32) Allocator.Error![]u8 {
    return try toast_activation.buildLaunchArg(alloc, .{
        .surface_id = pane,
        .tab_id = tab_id,
        .window_id = window_id,
        .pid = sys.GetCurrentProcessId(),
        .action = .focus,
    });
}

/// The most of a tab's title a toast shows, in bytes, before the ellipsis.
const tab_title_max = 64;

fn fallbackTitled(title: []const u8) bool {
    return title.len > 0 and !std.mem.eql(u8, title, "noctty");
}

/// The banner says what the toast would have: `<title>: <body>`, the
/// body alone when the title is empty or just "noctty", and the tab
/// the toast came from after a dash.
fn composeFallback(
    writer: *std.Io.Writer,
    title: []const u8,
    body: []const u8,
    attribution: ?[]const u8,
) std.Io.Writer.Error!void {
    const titled = fallbackTitled(title);
    if (titled) try writer.writeAll(title);
    if (body.len > 0) {
        if (titled) try writer.writeAll(": ");
        try writer.writeAll(body);
    }
    if (attribution) |line| try writer.print(" \u{2014} {s}", .{line});
}

/// The line a toast from tab `index` (from 0) carries, naming the tab:
/// `Tab N: <name>`, `Tab N of window M: <name>` while more than one window
/// is open, or `Tab N of the quick terminal: <name>`. The quick terminal is
/// not counted as a window, so a window and an idle quick terminal don't
/// number the window. The numbers are noctty's own, so a program can't pass
/// for another tab; the name is sanitized and cut to `tab_title_max` bytes.
fn writeTabLine(
    writer: *std.Io.Writer,
    index: usize,
    window: Window,
    name: []const u8,
) std.Io.Writer.Error!void {
    try writer.print("Tab {d}", .{index + 1});
    switch (window) {
        .quick_terminal => try writer.writeAll(" of the quick terminal"),
        .ordinary => |ordinary| if (ordinary.open > 1) {
            if (ordinary.number) |n| try writer.print(" of window {d}", .{n});
        },
    }
    try writer.writeAll(": ");
    try win32_program_status.writeSanitized(writer, name, tab_title_max);
}

pub const testing = struct {
    const Hook = struct { ctx: *anyopaque, run: *const fn (*anyopaque) anyerror!void };

    /// A pane in tab `tab_id`, at `index`, of window 7, the only window.
    pub fn inTab(tab_id: u32, index: usize, name: []const u8) Pane {
        return .{ .window_id = 7, .tab = .{
            .id = tab_id,
            .index = index,
            .name = name,
            .window = .{ .ordinary = .{ .number = 1, .open = 1 } },
        } };
    }

    /// Records what a sink is handed, in place of WinRT.
    pub const Recorder = struct {
        alloc: Allocator = std.testing.allocator,
        shown: usize = 0,
        /// Refuse every toast with this error, as Windows does when
        /// notifications are turned off for noctty; the request is still
        /// recorded.
        refuse: ?anyerror = null,
        /// Runs inside the show, after the request is recorded, as the
        /// messages a show can pump would.
        during_show: ?Hook = null,
        /// Runs inside a tag removal, after it is recorded, as the messages
        /// a history call can pump would.
        during_remove: ?Hook = null,
        title: ?[]u8 = null,
        body: ?[]u8 = null,
        attribution: ?[]u8 = null,
        launch: ?[]u8 = null,
        tag: ?[]u8 = null,
        group: ?[]u8 = null,
        /// Every history call, in order: `tag <tag> <group>` for one pane's
        /// toast, `group <group>` for a whole group.
        removals: std.ArrayListUnmanaged([]u8) = .empty,

        pub fn sink(self: *Recorder) ToastSink {
            return .{ .ctx = self, .show = record, .remove_tag = recordRemoveTag, .remove_group = recordRemoveGroup };
        }

        fn record(ctx: *anyopaque, request: ToastRequest) anyerror!void {
            const self: *Recorder = @ptrCast(@alignCast(ctx));
            self.clear();
            self.shown += 1;
            self.title = try self.alloc.dupe(u8, request.title);
            self.body = try self.alloc.dupe(u8, request.body);
            if (request.attribution) |value| self.attribution = try self.alloc.dupe(u8, value);
            if (request.launch) |value| self.launch = try self.alloc.dupe(u8, value);
            if (request.tag) |value| self.tag = try self.alloc.dupe(u8, value);
            if (request.group) |value| self.group = try self.alloc.dupe(u8, value);
            if (self.during_show) |hook| try hook.run(hook.ctx);
            if (self.refuse) |err| return err;
        }

        fn recordRemoveTag(ctx: *anyopaque, tag: []const u8, group: []const u8) anyerror!void {
            const self: *Recorder = @ptrCast(@alignCast(ctx));
            const line = try std.fmt.allocPrint(self.alloc, "tag {s} {s}", .{ tag, group });
            errdefer self.alloc.free(line);
            try self.removals.append(self.alloc, line);
            if (self.during_remove) |hook| try hook.run(hook.ctx);
        }

        fn recordRemoveGroup(ctx: *anyopaque, group: []const u8) anyerror!void {
            const self: *Recorder = @ptrCast(@alignCast(ctx));
            const line = try std.fmt.allocPrint(self.alloc, "group {s}", .{group});
            errdefer self.alloc.free(line);
            try self.removals.append(self.alloc, line);
        }

        /// Forget the last toast's fields.
        fn clear(self: *Recorder) void {
            inline for (.{ "title", "body", "attribution", "launch", "tag", "group" }) |name| {
                if (@field(self, name)) |value| self.alloc.free(value);
                @field(self, name) = null;
            }
        }

        pub fn deinit(self: *Recorder) void {
            self.clear();
            for (self.removals.items) |line| self.alloc.free(line);
            self.removals.deinit(self.alloc);
        }

        /// The history calls so far are exactly `expected`, in order.
        pub fn expectRemovals(self: *const Recorder, expected: []const []const u8) !void {
            try std.testing.expectEqual(expected.len, self.removals.items.len);
            for (expected, self.removals.items) |want, got| try std.testing.expectEqualStrings(want, got);
        }

        /// The history calls so far took exactly these panes' toasts, in
        /// order, each by its tag in this process's group.
        pub fn expectRemoved(self: *const Recorder, panes: []const u64) !void {
            try std.testing.expectEqual(panes.len, self.removals.items.len);
            var group_buf: [toast_group_max]u8 = undefined;
            const group = toastGroup(&group_buf);
            for (panes, self.removals.items) |pane, got| {
                var want_buf: [64]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want_buf, "tag {x:0>16} {s}", .{ pane, group }), got);
            }
        }

        /// Fails with an error, never a panic, when the field is missing: a
        /// panic would end the test process and hide every later failure.
        pub fn expect(
            self: *const Recorder,
            comptime field: enum { title, body, attribution, tag, group },
            expected: []const u8,
        ) !void {
            const actual = @field(self, @tagName(field)) orelse return error.TestExpectedText;
            try std.testing.expectEqualStrings(expected, actual);
        }

        /// The last toast's launch names `pane` in tab `tab_id` (null: none)
        /// of window `window_id`, in this process.
        pub fn expectLaunch(self: *const Recorder, pane: u64, tab_id: ?u32, window_id: u32) !void {
            const parsed = try toast_activation.parseLaunchArg(self.launch orelse return error.TestExpectedLaunch);
            try std.testing.expect(parsed.eql(.{
                .surface_id = pane,
                .tab_id = tab_id,
                .window_id = window_id,
                .pid = sys.GetCurrentProcessId(),
                .action = .focus,
            }));
        }
    };

    /// Panes a test lays out by id, in place of the App's windows.
    pub const FakePanes = struct {
        items: [8]struct { id: u64, pane: Pane } = undefined,
        len: usize = 0,
        /// Calls of `wake`; each fails while `wake_fails` (no message
        /// window).
        wakes: usize = 0,
        wake_fails: bool = false,
        /// No window can hold a banner.
        no_banner: bool = false,
        /// Who the last banner asked for was from, and the text of the last
        /// one a window took.
        banner_from: ?From = null,
        banner_buf: [256]u8 = undefined,
        banner_text: ?[]const u8 = null,
        /// Every `present` asked for, in order, found or not.
        presented: [16]Present = undefined,
        presents: usize = 0,

        pub fn panes(self: *FakePanes) Panes {
            return .{ .ctx = self, .find = find, .present = present, .banner = banner, .wake = wake };
        }

        /// The `present` calls so far are exactly `expected`, in order.
        pub fn expectPresented(self: *const FakePanes, expected: []const Present) !void {
            try std.testing.expectEqual(expected.len, self.presents);
            for (expected, self.presented[0..self.presents]) |want, got| try std.testing.expectEqual(want, got);
        }

        /// Add pane `id`, or change what is known of it.
        pub fn put(self: *FakePanes, id: u64, pane: Pane) void {
            for (self.items[0..self.len]) |*item| {
                if (item.id == id) {
                    item.pane = pane;
                    return;
                }
            }
            self.items[self.len] = .{ .id = id, .pane = pane };
            self.len += 1;
        }

        /// Pane `id` is gone.
        pub fn remove(self: *FakePanes, id: u64) void {
            for (self.items[0..self.len], 0..) |item, i| {
                if (item.id != id) continue;
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
                return;
            }
        }

        fn find(ctx: *anyopaque, id: u64) ?Pane {
            const self: *FakePanes = @ptrCast(@alignCast(ctx));
            for (self.items[0..self.len]) |item| {
                if (item.id == id) return item.pane;
            }
            return null;
        }

        /// As the App's: a pane by id, a tab by window and tab id, and a
        /// window, or any window for the primary one, that has a tab.
        fn present(ctx: *anyopaque, which: Present) bool {
            const self: *FakePanes = @ptrCast(@alignCast(ctx));
            self.presented[self.presents] = which;
            self.presents += 1;
            for (self.items[0..self.len]) |item| switch (which) {
                .pane => |id| if (item.id == id) return true,
                .tab => |want| if (item.pane.tab) |tab| {
                    if (item.pane.window_id == want.window and tab.id == want.tab) return true;
                },
                .window => |id| if (item.pane.window_id == id and item.pane.tab != null) return true,
                .primary => if (item.pane.tab != null) return true,
            };
            return false;
        }

        fn banner(ctx: *anyopaque, from: From, text: []const u8) bool {
            const self: *FakePanes = @ptrCast(@alignCast(ctx));
            self.banner_from = from;
            if (self.no_banner) return false;
            // As the App's: no window holds a pane it does not have.
            switch (from) {
                .app => {},
                .pane => |id| if (find(ctx, id) == null) return false,
            }
            @memcpy(self.banner_buf[0..text.len], text);
            self.banner_text = self.banner_buf[0..text.len];
            return true;
        }

        fn wake(ctx: *anyopaque) bool {
            const self: *FakePanes = @ptrCast(@alignCast(ctx));
            self.wakes += 1;
            return !self.wake_fails;
        }
    };
};

/// A pane of window 7 waiting in undo history.
const parked: Pane = .{ .window_id = 7, .tab = null };

const TestNotifications = struct {
    recorder: testing.Recorder = .{},
    panes: testing.FakePanes = .{},
    n: Notifications = undefined,

    fn init(self: *TestNotifications) void {
        self.n = .init(std.testing.allocator, self.recorder.sink(), self.panes.panes());
    }

    fn deinit(self: *TestNotifications) void {
        self.n.deinit();
        self.recorder.deinit();
    }

    /// Run `body` once, inside the next show or removal.
    fn once(self: *TestNotifications, comptime field: []const u8, context: anytype) void {
        const Context = @TypeOf(context.*);
        @field(self.recorder, field) = .{ .ctx = context, .run = struct {
            fn run(ctx: *anyopaque) anyerror!void {
                const typed: *Context = @ptrCast(@alignCast(ctx));
                @field(typed.t.recorder, field) = null;
                typed.body();
            }
        }.run };
    }
};

/// The pane's tab is seen, inside a show (`TestNotifications.once`).
const SeenDuringShow = struct {
    t: *TestNotifications,
    pane: u64,

    fn body(self: *SeenDuringShow) void {
        self.t.n.seen(self.pane);
    }
};

test "a pane's toast is tagged by the pane, grouped by process and launches it" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));

    t.n.show(.{ .pane = 0x2002 }, "", "tests passed");
    try t.recorder.expect(.tag, "0000000000002002");
    var group_buf: [32]u8 = undefined;
    const group = try std.fmt.bufPrint(&group_buf, "noctty-{d}", .{sys.GetCurrentProcessId()});
    try t.recorder.expect(.group, group);
    try t.recorder.expectLaunch(0x2002, 2, 7);
    // Untitled (OSC 9), it is titled by its tab.
    try t.recorder.expect(.title, "cargo build");
    try t.recorder.expect(.body, "tests passed");
    try t.recorder.expect(.attribution, "Tab 2: cargo build");

    // Every later toast from the pane, of any kind, has the same tag and
    // group, so Windows replaces the older one; a title is kept.
    t.n.show(.{ .pane = 0x2002 }, "deploy", "rolled out");
    try t.recorder.expect(.title, "deploy");
    try t.recorder.expect(.tag, "0000000000002002");
    try t.recorder.expect(.group, group);

    // Another pane has its own tag. One in no live tab still launches its
    // window, with no tab and no tab line.
    t.panes.put(0x2003, parked);
    t.n.show(.{ .pane = 0x2003 }, "", "x");
    try t.recorder.expect(.tag, "0000000000002003");
    try t.recorder.expect(.title, "noctty");
    try std.testing.expect(t.recorder.attribution == null);
    try t.recorder.expectLaunch(0x2003, null, 7);
    try std.testing.expectEqual(@as(usize, 3), t.recorder.shown);
}

test "an app's toast has no tag, launch or tab line, nor has one from a pane no window has" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();

    t.n.show(.app, "", "Configuration reloaded");
    try t.recorder.expect(.title, "noctty");
    try t.recorder.expect(.body, "Configuration reloaded");
    t.n.show(.{ .pane = 0x9999 }, "deploy", "rolled out");
    try t.recorder.expect(.title, "deploy");
    for ([_]?[]u8{ t.recorder.tag, t.recorder.group, t.recorder.launch, t.recorder.attribution }) |field| {
        try std.testing.expect(field == null);
    }
    try std.testing.expectEqual(@as(usize, 2), t.recorder.shown);

    // Neither is tracked, so there is nothing to remove, now or at exit.
    t.n.panesChanged();
    try std.testing.expectEqual(@as(usize, 0), t.panes.wakes);
    t.n.deinit();
    try t.recorder.expectRemoved(&.{});

    // Refused, the unknown pane's banner is asked of that pane, which no
    // window holds, so it is a log line.
    t.recorder.refuse = error.NotifierDisabled;
    t.n.show(.{ .pane = 0x9999 }, "deploy", "rolled out");
    try std.testing.expectEqual(From{ .pane = 0x9999 }, t.panes.banner_from.?);
    try std.testing.expect(t.panes.banner_text == null);
}

test "a toast's tab line names the window only while several are open, and the quick terminal" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();

    const cases = [_]struct { window: Window, line: []const u8 }{
        .{ .window = .{ .ordinary = .{ .number = 1, .open = 1 } }, .line = "Tab 2: ssh" },
        .{ .window = .{ .ordinary = .{ .number = 2, .open = 2 } }, .line = "Tab 2 of window 2: ssh" },
        // A window that is not registered gets no number.
        .{ .window = .{ .ordinary = .{ .number = null, .open = 2 } }, .line = "Tab 2: ssh" },
        // The quick terminal is named, not numbered.
        .{ .window = .quick_terminal, .line = "Tab 2 of the quick terminal: ssh" },
    };
    for (cases) |case| {
        t.panes.put(0x3003, .{ .window_id = 8, .tab = .{ .id = 5, .index = 1, .name = "ssh", .window = case.window } });
        t.n.show(.{ .pane = 0x3003 }, "", "x");
        try t.recorder.expect(.attribution, case.line);
    }
}

test "a toast shows its tab's name without controls or bidi overrides, cut to 64 bytes on a code point" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();

    const cases = [_]struct { name: []const u8, shown: []const u8 }{
        // Bidi overrides and invisible characters go; controls are spaces.
        .{ .name = "a\u{202E}<b>&\u{200B}\x07c", .shown = "a<b>& c" },
        // U+FFFE and U+FFFF, which XML 1.0 cannot carry, so Windows would
        // refuse the toast.
        .{ .name = "x\u{FFFE}y\u{FFFF}z", .shown = "x y z" },
        // 21 three-byte characters fit in 64 bytes.
        .{ .name = "安" ** 30, .shown = "安" ** 21 ++ "\u{2026}" },
    };
    for (cases) |case| {
        t.panes.put(0x2002, testing.inTab(2, 1, case.name));
        t.n.show(.{ .pane = 0x2002 }, "", "x");
        try t.recorder.expect(.title, case.shown);
        var line_buf: [96]u8 = undefined;
        try t.recorder.expect(.attribution, try std.fmt.bufPrint(&line_buf, "Tab 2: {s}", .{case.shown}));
    }
}

test "a refused toast becomes a banner that names its tab once, else a log line" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    // As when notifications are turned off for noctty in Windows Settings.
    t.recorder.refuse = error.NotifierDisabled;
    t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));
    const pane: From = .{ .pane = 0x2002 };

    // An untitled toast is titled by its tab, but the banner does not
    // repeat the tab's title before the tab line.
    t.n.show(pane, "", "tests passed");
    try t.recorder.expect(.title, "cargo build");
    try std.testing.expectEqual(pane, t.panes.banner_from.?);
    try std.testing.expectEqualStrings("tests passed \u{2014} Tab 2: cargo build", t.panes.banner_text.?);
    t.n.show(pane, "deploy", "rolled out");
    try std.testing.expectEqualStrings("deploy: rolled out \u{2014} Tab 2: cargo build", t.panes.banner_text.?);
    // The core's clipboard-copy notice comes from its pane as an OSC 777
    // titled "noctty" would.
    t.n.show(pane, "noctty", "Copied selection to clipboard");
    try std.testing.expectEqualStrings("Copied selection to clipboard \u{2014} Tab 2: cargo build", t.panes.banner_text.?);

    // An app notification names no tab; one with only a title (a Settings
    // save) is its title.
    t.n.show(.app, "", "Configuration reloaded");
    try std.testing.expectEqual(From.app, t.panes.banner_from.?);
    try std.testing.expectEqualStrings("Configuration reloaded", t.panes.banner_text.?);
    t.n.show(.app, "Settings saved", "");
    try std.testing.expectEqualStrings("Settings saved", t.panes.banner_text.?);
    try std.testing.expectEqual(@as(usize, 5), t.recorder.shown);

    // With no window to hold a banner the text goes to the log.
    t.panes.no_banner = true;
    t.n.show(pane, "claude is done", "");
    try std.testing.expectEqualStrings("Settings saved", t.panes.banner_text.?);

    // Nothing Windows refused is tracked or removed.
    t.n.panesChanged();
    try std.testing.expectEqual(@as(usize, 0), t.panes.wakes);
    t.n.deinit();
    try t.recorder.expectRemoved(&.{});
}

test "without a sink every notification is a banner and nothing is tracked" {
    var panes: testing.FakePanes = .{};
    var n: Notifications = .init(std.testing.allocator, null, panes.panes());
    panes.put(0x2002, testing.inTab(2, 1, "cargo build"));
    n.show(.{ .pane = 0x2002 }, "", "tests passed");
    try std.testing.expectEqualStrings("tests passed \u{2014} Tab 2: cargo build", panes.banner_text.?);
    n.seen(0x2002);
    n.panesChanged();
    n.flush();
    n.deinit();
    try std.testing.expectEqual(@as(usize, 0), panes.wakes);

    // A disabled one has no window to find, and allocates nothing it keeps.
    var disabled: Notifications = .disabled;
    disabled.show(.{ .pane = 0x2002 }, "", "x");
    disabled.panesChanged();
    disabled.deinit();
}

test "seeing a tab and changing panes call nothing in Windows but one wake, retried when it fails" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x1001, testing.inTab(1, 0, "pwsh"));
    t.n.show(.{ .pane = 0x1001 }, "", "x");
    try std.testing.expectEqual(@as(usize, 0), t.panes.wakes);

    // No message window yet: the wake fails, and the next call asks again.
    t.panes.wake_fails = true;
    t.n.seen(0x1001);
    try std.testing.expectEqual(@as(usize, 1), t.panes.wakes);
    t.panes.wake_fails = false;
    t.n.panesChanged();
    try std.testing.expectEqual(@as(usize, 2), t.panes.wakes);
    // One wake is in flight: no second one.
    t.n.seen(0x1001);
    t.n.panesChanged();
    try std.testing.expectEqual(@as(usize, 2), t.panes.wakes);
    try t.recorder.expectRemoved(&.{});
    try std.testing.expectEqual(@as(usize, 1), t.recorder.shown);

    t.n.flush();
    try t.recorder.expectRemoved(&.{0x1001});
    // Nothing is tracked now, so a change posts nothing.
    t.n.panesChanged();
    try std.testing.expectEqual(@as(usize, 2), t.panes.wakes);
}

test "a seen, closed or parked pane's toast is removed once at the flush, and one back in a tab stays" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    for ([_]u64{ 0xA, 0xB, 0xC, 0xD, 0xE, 0xF }, 0..) |pane, i| {
        t.panes.put(pane, testing.inTab(@intCast(i + 1), i, "x"));
        t.n.show(.{ .pane = pane }, "", "x");
    }

    t.n.seen(0xA);
    t.panes.remove(0xB);
    t.panes.put(0xC, parked);
    t.panes.put(0xD, parked);
    t.n.panesChanged();
    // D's tab comes back (an undo) before the flush. E leaves its tab with
    // no call at all: what the flush finds counts, not what it was told.
    t.panes.put(0xD, testing.inTab(4, 3, "x"));
    t.panes.put(0xE, parked);
    t.n.flush();
    // In the order the toasts were shown.
    try t.recorder.expectRemoved(&.{ 0xA, 0xB, 0xC, 0xE });
    t.n.flush();
    try t.recorder.expectRemoved(&.{ 0xA, 0xB, 0xC, 0xE });

    // Seen in the other order, still removed in the order shown.
    t.n.seen(0xF);
    t.n.seen(0xD);
    t.n.flush();
    try t.recorder.expectRemoved(&.{ 0xA, 0xB, 0xC, 0xE, 0xD, 0xF });
}

test "a pane's newer toast survives a seen of its tab during its show" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x1001, testing.inTab(1, 0, "pwsh"));
    t.n.show(.{ .pane = 0x1001 }, "", "older");

    // The show pumps the activation of the pane's tab, which sees the older
    // toast; the newer one replaces it, so the flush must not take it.
    var seen: SeenDuringShow = .{ .t = &t, .pane = 0x1001 };
    t.once("during_show", &seen);
    t.n.show(.{ .pane = 0x1001 }, "", "newer");
    t.n.flush();
    try t.recorder.expectRemoved(&.{});
    t.n.seen(0x1001);
    t.n.flush();
    try t.recorder.expectRemoved(&.{0x1001});
}

test "a pane that leaves its tab during its toast's show has the toast removed" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));

    // The show pumps the undo-close of the pane's tab and the flush that
    // close asked for, which cannot take a toast still in the sink.
    var close = struct {
        t: *TestNotifications,
        removed_inside: usize = 0,
        fn body(self: *@This()) void {
            self.t.panes.put(0x2002, parked);
            self.t.n.panesChanged();
            self.t.n.flush();
            self.removed_inside = self.t.recorder.removals.items.len;
        }
    }{ .t = &t };
    t.once("during_show", &close);
    t.n.show(.{ .pane = 0x2002 }, "", "x");
    try std.testing.expectEqual(@as(usize, 0), close.removed_inside);
    // The close's wake, then the show's own: the toast is in Action Center
    // now, for a pane in no tab.
    try std.testing.expectEqual(@as(usize, 2), t.panes.wakes);
    t.n.flush();
    try t.recorder.expectRemoved(&.{0x2002});
}

test "a refused newer toast leaves the older one's removal standing" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x1001, testing.inTab(1, 0, "pwsh"));

    // The older toast's removal is due; Windows refuses the newer one
    // (notifications turned off meanwhile), so the older is still there.
    t.n.show(.{ .pane = 0x1001 }, "", "older");
    t.n.seen(0x1001);
    t.recorder.refuse = error.NotifierDisabled;
    t.n.show(.{ .pane = 0x1001 }, "", "newer");
    t.n.flush();
    try t.recorder.expectRemoved(&.{0x1001});

    // A refused toast with an unseen older one keeps that one.
    t.recorder.refuse = null;
    t.n.show(.{ .pane = 0x1001 }, "", "older");
    t.recorder.refuse = error.NotifierDisabled;
    t.n.show(.{ .pane = 0x1001 }, "", "newer");
    t.n.flush();
    try t.recorder.expectRemoved(&.{0x1001});

    // A seen of the tab while the refused toast was in the sink was a seen
    // of the older toast.
    var seen: SeenDuringShow = .{ .t = &t, .pane = 0x1001 };
    t.once("during_show", &seen);
    t.n.show(.{ .pane = 0x1001 }, "", "newer");
    t.n.flush();
    try t.recorder.expectRemoved(&.{ 0x1001, 0x1001 });
}

test "a toast shown for a pane inside another show for it is the one tracked" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x1001, testing.inTab(1, 0, "pwsh"));

    // The outer show pumps a newer toast for the same pane, which Windows
    // takes, and then refuses the outer one: the newer toast is the pane's.
    var nested = struct {
        t: *TestNotifications,
        fn body(self: *@This()) void {
            self.t.recorder.refuse = null;
            self.t.n.show(.{ .pane = 0x1001 }, "", "nested");
            self.t.recorder.refuse = error.NotifierDisabled;
        }
    }{ .t = &t };
    t.once("during_show", &nested);
    t.n.show(.{ .pane = 0x1001 }, "", "outer");
    try std.testing.expectEqual(@as(usize, 2), t.recorder.shown);
    t.n.seen(0x1001);
    t.n.flush();
    try t.recorder.expectRemoved(&.{0x1001});
}

test "a toast whose nested show was seen and removed during it is tracked again" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x1001, testing.inTab(1, 0, "pwsh"));

    // The outer show pumps a newer toast for the same pane, which Windows
    // takes; the tab is seen and a flush removes that one, all before the
    // outer show returns. Windows then takes the outer toast too: it is the
    // pane's, and the next seen tab removes it.
    var nested = struct {
        t: *TestNotifications,
        fn body(self: *@This()) void {
            self.t.n.show(.{ .pane = 0x1001 }, "", "nested");
            self.t.n.seen(0x1001);
            self.t.n.flush();
        }
    }{ .t = &t };
    t.once("during_show", &nested);
    t.n.show(.{ .pane = 0x1001 }, "", "outer");
    try std.testing.expectEqual(@as(usize, 2), t.recorder.shown);
    try t.recorder.expectRemoved(&.{0x1001});
    t.n.seen(0x1001);
    t.n.flush();
    try t.recorder.expectRemoved(&.{ 0x1001, 0x1001 });
}

test "a removal takes its entry off before its call, and a toast shown meanwhile stays" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0xA, testing.inTab(1, 0, "a"));
    t.panes.put(0xB, testing.inTab(2, 1, "b"));
    t.n.show(.{ .pane = 0xA }, "", "x");
    t.n.show(.{ .pane = 0xB }, "", "x");
    t.n.seen(0xA);
    t.n.seen(0xB);

    // A's history call pumps a newer toast from B, whose older one was due
    // to go, and a flush another message asked for.
    var pumped = struct {
        t: *TestNotifications,
        fn body(self: *@This()) void {
            self.t.n.show(.{ .pane = 0xB }, "", "newer");
            self.t.n.flush();
        }
    }{ .t = &t };
    t.once("during_remove", &pumped);
    t.n.flush();
    try t.recorder.expectRemoved(&.{0xA});
    t.n.seen(0xB);
    t.n.flush();
    try t.recorder.expectRemoved(&.{ 0xA, 0xB });
}

test "exit removes this process's group once, after a tagged toast" {
    var group_buf: [32]u8 = undefined;
    const own_group = try std.fmt.bufPrint(&group_buf, "group noctty-{d}", .{sys.GetCurrentProcessId()});

    // The process's own group, in one call, and nothing else: not one
    // removal per pane, also for one still due, and never the AUMID-wide
    // `Clear`, which would take other noctty processes' toasts too. One
    // that showed no tagged toast makes no call: the app toast and refused
    // toast tests check that.
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0xA, testing.inTab(1, 0, "a"));
    t.panes.put(0xB, testing.inTab(2, 1, "b"));
    t.n.show(.{ .pane = 0xA }, "", "x");
    t.n.show(.{ .pane = 0xB }, "", "x");
    t.n.seen(0xA);
    t.n.deinit();
    try t.recorder.expectRemovals(&.{own_group});
    t.n.deinit();
    try t.recorder.expectRemovals(&.{own_group});
}

test "out of memory drops what it cannot build or track" {
    const pane: From = .{ .pane = 0x2002 };

    // How many allocations a tracked show makes: the last is its entry.
    const allocations = count: {
        var t: TestNotifications = .{};
        var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
        t.n = .init(counting.allocator(), t.recorder.sink(), t.panes.panes());
        defer t.deinit();
        t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));
        t.n.show(pane, "", "x");
        // Tracked: a change asks for a flush.
        t.n.panesChanged();
        try std.testing.expectEqual(@as(usize, 1), t.panes.wakes);
        break :count counting.alloc_index;
    };

    // No memory for the launch: nothing is shown, no banner is asked for
    // and nothing is tracked, so exit has nothing to remove.
    {
        var t: TestNotifications = .{};
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
        t.n = .init(failing.allocator(), t.recorder.sink(), t.panes.panes());
        defer t.deinit();
        t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));
        t.n.show(pane, "", "x");
        try std.testing.expectEqual(@as(usize, 0), t.recorder.shown);
        try std.testing.expect(t.panes.banner_from == null);
        t.n.panesChanged();
        try std.testing.expectEqual(@as(usize, 0), t.panes.wakes);
        t.n.deinit();
        try t.recorder.expectRemoved(&.{});
    }

    // No memory for its entry: the toast is not shown, since it could not
    // leave when its tab is seen or its pane closes, and no banner stands in.
    {
        var t: TestNotifications = .{};
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = allocations - 1 });
        t.n = .init(failing.allocator(), t.recorder.sink(), t.panes.panes());
        defer t.deinit();
        t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));
        t.n.show(pane, "", "x");
        try std.testing.expectEqual(@as(usize, 0), t.recorder.shown);
        try std.testing.expect(t.panes.banner_from == null);
        t.n.panesChanged();
        try std.testing.expectEqual(@as(usize, 0), t.panes.wakes);
        t.n.deinit();
        try t.recorder.expectRemoved(&.{});
    }

    // No memory for a refused toast's banner text: no banner, a log line.
    {
        var t: TestNotifications = .{};
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
        t.n = .init(failing.allocator(), t.recorder.sink(), t.panes.panes());
        defer t.deinit();
        t.recorder.refuse = error.NotifierDisabled;
        t.n.show(.app, "", "Configuration reloaded");
        try std.testing.expectEqual(@as(usize, 1), t.recorder.shown);
        try std.testing.expect(t.panes.banner_from == null);
    }
}

/// A click on a toast of this process.
fn ownClick(target: toast_activation.ActivationTarget) Click {
    var own = target;
    own.pid = sys.GetCurrentProcessId();
    own.action = .focus;
    return .{ .target = own };
}

test "a click from another process, or with no pid, presents only the primary window" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));

    // The ids are another process's: one that happens to match here must
    // not be picked.
    const ids: toast_activation.ActivationTarget = .{ .surface_id = 0x2002, .tab_id = 2, .window_id = 7, .action = .focus };
    var foreign = ids;
    foreign.pid = sys.GetCurrentProcessId() +% 4;
    try std.testing.expectEqual(Outcome.done, t.n.click(.{ .target = foreign }));
    try t.panes.expectPresented(&.{.primary});
    try std.testing.expectEqual(Outcome.done, t.n.click(.{ .target = ids }));
    try t.panes.expectPresented(&.{ .primary, .primary });

    // The same ids from this process name the pane.
    try std.testing.expectEqual(Outcome.done, t.n.click(ownClick(ids)));
    try t.panes.expectPresented(&.{ .primary, .primary, .{ .pane = 0x2002 } });
}

test "a click presents its pane, else its window's tab, else its window, else the primary window" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));

    // The toast's pane is gone, but its tab is still there.
    _ = t.n.click(ownClick(.{ .surface_id = 0x9999, .tab_id = 2, .window_id = 7 }));
    try t.panes.expectPresented(&.{ .{ .pane = 0x9999 }, .{ .tab = .{ .window = 7, .tab = 2 } } });
    // So is its window, without the tab.
    t.panes.presents = 0;
    _ = t.n.click(ownClick(.{ .surface_id = 0x9999, .tab_id = 9, .window_id = 7 }));
    try t.panes.expectPresented(&.{ .{ .pane = 0x9999 }, .{ .tab = .{ .window = 7, .tab = 9 } }, .{ .window = 7 } });
    // And with its window gone too, the primary window.
    t.panes.presents = 0;
    _ = t.n.click(ownClick(.{ .window_id = 8 }));
    try t.panes.expectPresented(&.{ .{ .window = 8 }, .primary });
}

test "the same click twice acts once, also with another click in between" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x1001, testing.inTab(1, 0, "pwsh"));
    t.panes.put(0x2002, testing.inTab(2, 1, "cargo build"));

    const first = ownClick(.{ .surface_id = 0x1001 });
    const second = ownClick(.{ .surface_id = 0x2002 });
    for ([_]Click{ first, second, first, second }) |what| {
        try std.testing.expectEqual(Outcome.done, t.n.click(what));
    }
    try t.panes.expectPresented(&.{ .{ .pane = 0x1001 }, .{ .pane = 0x2002 } });
}

test "a click with nowhere to go asks for a window, and the newest is presented once one opens" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();

    try std.testing.expectEqual(Outcome.needs_window, t.n.click(ownClick(.{ .surface_id = 0x1001 })));
    try std.testing.expectEqual(Outcome.needs_window, t.n.click(ownClick(.{ .surface_id = 0x2002 })));
    t.panes.presents = 0;
    // A window that opens empty presents nothing yet.
    _ = t.n.click(.window_opened);
    try t.panes.expectPresented(&.{ .{ .pane = 0x2002 }, .primary });

    t.panes.presents = 0;
    t.panes.put(0x2002, testing.inTab(2, 0, "cargo build"));
    try std.testing.expectEqual(Outcome.done, t.n.click(.window_opened));
    try t.panes.expectPresented(&.{.{ .pane = 0x2002 }});
    // Presented once.
    _ = t.n.click(.window_opened);
    try t.panes.expectPresented(&.{.{ .pane = 0x2002 }});
}

test "the click a process starts for is kept unfiltered for its first window" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    const own = ownClick(.{ .surface_id = 0x2002 }).target;

    // A start presents nothing until a window opens, and does not count
    // as a delivery of the click.
    try std.testing.expectEqual(Outcome.done, t.n.click(.{ .start = own }));
    try std.testing.expectEqual(Outcome.done, t.n.click(.{ .start = own }));
    try t.panes.expectPresented(&.{});
    t.panes.put(0x2002, testing.inTab(2, 0, "cargo build"));
    _ = t.n.click(.window_opened);
    try t.panes.expectPresented(&.{.{ .pane = 0x2002 }});
    try std.testing.expectEqual(Outcome.done, t.n.click(.{ .target = own }));
    try t.panes.expectPresented(&.{ .{ .pane = 0x2002 }, .{ .pane = 0x2002 } });
}

test "a window opening with no click kept presents nothing" {
    var t: TestNotifications = .{};
    t.init();
    defer t.deinit();
    t.panes.put(0x2002, testing.inTab(2, 0, "cargo build"));
    try std.testing.expectEqual(Outcome.done, t.n.click(.window_opened));
    try t.panes.expectPresented(&.{});
}

const ColdToastWaitTest = struct {
    const Timer = struct {
        var capture: ColdToastCapture = .{};

        fn fire(_: ?sys.HWND, _: sys.UINT, id: win32_types.UINT_PTR, _: win32_types.DWORD) callconv(.winapi) void {
            _ = sys.KillTimer(null, id);
            ColdToastCapture.deliver(&capture, "wgh://activate?surface=3&pid=8&action=focus");
        }
    };

    fn body() !void {
        // Nothing comes: the wait returns at its deadline, not later.
        var none: ColdToastCapture = .{};
        const start = sys.GetTickCount64();
        try std.testing.expect(!pumpUntilColdToastActivation(&none, 60));
        const waited = sys.GetTickCount64() - start;
        try std.testing.expect(waited >= 40);
        try std.testing.expect(waited < 2000);

        // A call dispatched by the pump (here a timer procedure, as COM's call
        // is a dispatched message) ends it well before the deadline.
        Timer.capture = .{};
        try std.testing.expect(sys.SetTimer(null, 0, 10, @ptrCast(&Timer.fire)) != 0);
        const call_start = sys.GetTickCount64();
        try std.testing.expect(pumpUntilColdToastActivation(&Timer.capture, 10_000));
        try std.testing.expect(sys.GetTickCount64() - call_start < 5000);
        try std.testing.expect(Timer.capture.activation.eql(.{ .surface_id = 3, .pid = 8, .action = .focus }));

        // A quit ends the wait and stays queued for the main loop.
        var quit_capture: ColdToastCapture = .{};
        sys.PostQuitMessage(7);
        try std.testing.expect(!pumpUntilColdToastActivation(&quit_capture, 10_000));
        var msg: sys.MSG = undefined;
        try std.testing.expect(sys.PeekMessageW(&msg, null, c.WM_QUIT, c.WM_QUIT, c.PM_REMOVE) != 0);
        try std.testing.expectEqual(@as(sys.WPARAM, 7), msg.wParam);
    }

    fn run(result: *anyerror!void) void {
        body() catch |err| {
            // The test fails on the runner's thread; this trace shows which
            // check failed.
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
            result.* = err;
        };
    }
};

test "the cold toast activation wait ends on its call or at its deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // A fresh thread, so the pump dispatches nothing another test queued.
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{}, ColdToastWaitTest.run, .{&result});
    thread.join();
    return result;
}

test "a cold toast activation start keeps the first call and reads nothing else as a target" {
    const callback = win32_toast_activator.testCallback();
    // `Activate` reads only the launch string.
    const aumid: ?[*:0]const u16 = null;

    var capture: ColdToastCapture = .{};
    win32_toast_activator.bind(capture.sink());
    defer win32_toast_activator.bind(null);
    _ = callback.vtbl.Activate(callback, aumid, std.unicode.utf8ToUtf16LeStringLiteral("wgh://activate?surface=3&pid=8&action=focus"), null, 0);
    _ = callback.vtbl.Activate(callback, aumid, std.unicode.utf8ToUtf16LeStringLiteral("wgh://activate?surface=4&pid=8"), null, 0);
    try std.testing.expect(capture.received);
    try std.testing.expect(capture.activation.eql(.{ .surface_id = 3, .pid = 8, .action = .focus }));

    // A call that carried nothing readable still ends the wait, and its
    // target is the empty one, which only presents the primary window.
    var unreadable: ColdToastCapture = .{};
    win32_toast_activator.bind(unreadable.sink());
    _ = callback.vtbl.Activate(callback, aumid, std.unicode.utf8ToUtf16LeStringLiteral("--command=evil.exe"), null, 0);
    try std.testing.expect(unreadable.received);
    try std.testing.expect(unreadable.activation.eql(.{}));
}
