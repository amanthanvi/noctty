//! Desktop notifications: what noctty tells the user through Windows toasts,
//! when a toast leaves Action Center, and what a click on one brings forward.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const win32_program_status = @import("../win32_program_status.zig");
const toast_activation = @import("../win32_toast_activation.zig");
const win32_toast_winrt = @import("../win32_toast_winrt.zig");

pub const ToastRequest = win32_toast_winrt.ToastRequest;

/// Where a toast goes: WinRT in the product (`ToastSink.winrt`), a
/// recorder in tests (`testing.Recorder`), so no test can reach Action
/// Center.
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

/// A pane's toast tag: its core surface id, 16 hex digits. One tag per pane,
/// so a newer toast from the pane replaces its older one in Action Center.
pub fn toastTag(buf: *[16]u8, surface_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{surface_id}) catch unreachable;
}

/// This process's toast group, `noctty-<pid>`: other noctty processes share
/// the AUMID, so everything this process removes at once is named by it.
pub fn toastGroup(buf: *[toast_group_max]u8) []const u8 {
    return std.fmt.bufPrint(buf, "noctty-{d}", .{sys.GetCurrentProcessId()}) catch unreachable;
}

pub const toast_group_max = "noctty-".len + std.fmt.count("{d}", .{std.math.maxInt(u32)});

/// The launch string a click on a pane's toast brings back: the pane, its
/// tab (null in no tab), its window and this process.
pub fn buildLaunch(alloc: Allocator, pane: u64, tab_id: ?u32, window_id: u32) Allocator.Error![]u8 {
    return try toast_activation.buildLaunchArg(alloc, .{
        .surface_id = pane,
        .tab_id = tab_id,
        .window_id = window_id,
        .pid = sys.GetCurrentProcessId(),
        .action = .focus,
    });
}

/// The most of a tab's title a toast shows, in bytes, before the ellipsis.
pub const tab_title_max = 64;

pub fn fallbackTitled(title: []const u8) bool {
    return title.len > 0 and !std.mem.eql(u8, title, "noctty");
}

/// The banner says what the toast would have: `<title>: <body>`, the
/// body alone when the title is empty or just "noctty", and the tab
/// the toast came from after a dash.
pub fn composeFallback(
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

/// The window a tab is in, as its toast names it.
pub const Window = union(enum) {
    quick_terminal,
    /// `number` counts the open windows other than the quick terminal, in
    /// order, and is null for a window that is not registered.
    ordinary: struct { number: ?u32, open: u32 },
};

/// The line a toast from tab `index` (from 0) carries, naming the tab:
/// `Tab N: <name>`, `Tab N of window M: <name>` while more than one window
/// is open, or `Tab N of the quick terminal: <name>`. The quick terminal is
/// not counted as a window, so a window and an idle quick terminal don't
/// number the window. The numbers are noctty's own, so a program can't pass
/// for another tab; the name is sanitized and cut to `tab_title_max` bytes.
pub fn writeTabLine(
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
        during_show: ?struct { ctx: *anyopaque, run: *const fn (*anyopaque) anyerror!void } = null,
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

        /// The last toast's launch names `pane` in tab `tab_id` of window
        /// `window_id`.
        pub fn expectLaunch(self: *const Recorder, pane: u64, tab_id: u32, window_id: u32) !void {
            const parsed = try toast_activation.parseLaunchArg(self.launch orelse return error.TestExpectedLaunch);
            try std.testing.expectEqual(@as(?u64, pane), parsed.surface_id);
            try std.testing.expectEqual(@as(?u32, tab_id), parsed.tab_id);
            try std.testing.expectEqual(@as(?u32, window_id), parsed.window_id);
            try std.testing.expectEqual(@as(?toast_activation.Action, .focus), parsed.action);
        }
    };

    /// What a removal of `surface_id`'s toast reads in the recorder.
    pub fn expectedRemoval(buf: []u8, surface_id: u64) ![]const u8 {
        var group_buf: [toast_group_max]u8 = undefined;
        return std.fmt.bufPrint(buf, "tag {x:0>16} {s}", .{ surface_id, toastGroup(&group_buf) });
    }
};
