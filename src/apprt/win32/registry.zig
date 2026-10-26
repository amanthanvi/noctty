//! UI-thread registry of the App's existing host and surface references.
const std = @import("std");
const win32 = @import("../win32.zig");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const Allocator = std.mem.Allocator;
const Host = win32.Host;
const Surface = win32.Surface;
const Tab = win32.Tab;
const HWND = win32.HWND;
const RECT = win32.RECT;
const sys = @import("sys.zig");
const win32_structural_history = @import("../win32_structural_history.zig");
const win32_toast_activation = @import("../win32_toast_activation.zig");

/// App owns this registry; only the UI thread reads or mutates it, including
/// `message_hwnd`. App still orchestrates native creation and destruction.
/// Cross-thread producers use the retained AppDelivery channel, whose locked,
/// atomic HWND publication is closed before this UI-owned HWND is destroyed.
/// They never borrow these lists or read this copy of the handle.
pub const Registry = struct {
    hosts: std.ArrayListUnmanaged(*Host) = .empty,
    windows: std.ArrayListUnmanaged(*Surface) = .empty,
    message_hwnd: ?HWND = null,

    pub fn addHost(self: *Registry, alloc: Allocator, host: *Host) !void {
        try self.hosts.append(alloc, host);
    }

    pub fn addWindow(self: *Registry, alloc: Allocator, surface: *Surface) !void {
        try self.windows.append(alloc, surface);
    }

    /// Detach before Host.deinit, which can reenter App via native teardown.
    /// As before, removing the first match swaps the last reference into it.
    pub fn removeHost(self: *Registry, host: *Host) bool {
        return detachHostReference(&self.hosts, host);
    }

    /// The WinEvent callback already has the host HWND and must not interpret
    /// GWLP_USERDATA belonging to a window outside this App.
    pub fn findHostByHwnd(self: *Registry, hwnd: HWND) ?*Host {
        for (self.hosts.items) |host| {
            const host_hwnd = host.hwnd orelse continue;
            if (host_hwnd == hwnd) return host;
        }
        return null;
    }

    pub fn findHostById(self: *Registry, id: u32) ?*Host {
        for (self.hosts.items) |host| {
            if (host.id == id) return host;
        }
        return null;
    }

    /// The quick terminal is its host window, whatever tabs and splits it
    /// holds. Surfaces carry no flag of their own: one opened inside it later
    /// is as much the quick terminal as the pane it was created with, and
    /// that pane closing leaves it where it is.
    pub fn quickTerminalHost(self: *Registry) ?*Host {
        for (self.hosts.items) |host| {
            if (host.quick_terminal) return host;
        }
        return null;
    }

    pub fn activeSurfaceForHost(self: *Registry, host_id: u32) ?*Surface {
        const host = self.findHostById(host_id) orelse return null;
        return host.activeSurface();
    }

    pub fn findSurfaceById(self: *Registry, surface_id: u64) ?*Surface {
        for (self.windows.items) |surface| {
            if (surface.core().id == surface_id) return surface;
        }

        for (self.hosts.items) |host| {
            for (host.tabs.items) |*tab| {
                if (tab.findSurfaceByCoreId(surface_id)) |surface| return surface;
            }
        }

        return null;
    }

    pub fn findLiveSurfaceById(self: *Registry, surface_id: u64) ?*Surface {
        const surface = self.findSurfaceById(surface_id) orelse return null;
        _ = self.findTabForSurface(surface) orelse return null;
        return surface;
    }

    /// Whether a window on screen has its top-left corner where `rect` does,
    /// other than `except`.
    pub fn windowStartsAt(self: *Registry, rect: RECT, except: ?HWND) bool {
        for (self.hosts.items) |host| {
            const hwnd = host.hwnd orelse continue;
            if (hwnd == except or sys.IsWindowVisible(hwnd) == 0 or sys.IsIconic(hwnd) != 0) continue;
            var other: RECT = undefined;
            if (sys.GetWindowRect(hwnd, &other) == 0) continue;
            if (other.left == rect.left and other.top == rect.top) return true;
        }
        return false;
    }

    pub fn findSurfaceForTarget(self: *Registry, target: apprt.Target) ?*Surface {
        return switch (target) {
            .app => self.primarySurface(),
            .surface => |core_surface| self.findSurfaceByCore(core_surface),
        };
    }

    /// `findSurfaceForTarget`, unless its window is hidden: then the active
    /// surface of the first window on screen.
    pub fn shownSurfaceForTarget(self: *Registry, target: apprt.Target) ?*Surface {
        if (self.findSurfaceForTarget(target)) |surface| {
            if (surface.windowHwnd()) |hwnd| {
                if (sys.IsWindowVisible(hwnd) != 0) return surface;
            }
        }
        for (self.hosts.items) |host| {
            const hwnd = host.hwnd orelse continue;
            if (sys.IsWindowVisible(hwnd) == 0) continue;
            if (host.activeSurface()) |surface| return surface;
        }
        return null;
    }

    /// The window a new one copies its state from: the target's, or, for a
    /// request no window made (a forwarded launch), one from the quick
    /// terminal or one whose surface is gone, the ordinary window activated
    /// last. Never the quick terminal, a floating, undecorated strip pinned
    /// to a screen edge that a copy would repeat, and never a window kept
    /// with no tab for undo, which has no pane to copy. With neither, an
    /// ordinary new window. `hosts` is no guide: `detachHostReference`
    /// reorders it.
    pub fn newWindowSource(self: *Registry, target: apprt.Target) ?*Surface {
        switch (target) {
            .app => {},
            .surface => |core_surface| if (self.findSurfaceByCore(core_surface)) |surface| {
                const host = surface.host orelse return surface;
                if (!host.quick_terminal) return surface;
            },
        }
        var latest: ?*Host = null;
        for (self.hosts.items) |host| {
            if (host.quick_terminal or host.activeSurface() == null) continue;
            if (latest == null or host.activated > latest.?.activated) latest = host;
        }
        return if (latest) |host| host.activeSurface() else null;
    }

    pub fn focusedSurfaceForUndoRedo(self: *Registry) ?*Surface {
        for (self.hosts.items) |host| {
            if (host.activeSurface()) |surface| {
                if (surface.window_focused) return surface;
            }
        }

        for (self.windows.items) |surface| {
            if (surface.window_focused) return surface;
        }

        return null;
    }

    pub fn primarySurface(self: *Registry) ?*Surface {
        if (self.hosts.items.len == 0) return null;
        return self.activeSurfaceForHost(self.hosts.items[0].id);
    }

    pub fn hostWithNewestStructuralUndo(self: *Registry) ?*Host {
        var best: ?*Host = null;
        var best_ts: u64 = 0;
        var best_seq: u64 = 0;
        for (self.hosts.items) |host| {
            const entry = host.peekStructuralUndo() orelse continue;
            if (best == null or win32_structural_history.sortsAfter(
                entry.timestamp_ms,
                entry.sequence_id,
                best_ts,
                best_seq,
            )) {
                best = host;
                best_ts = entry.timestamp_ms;
                best_seq = entry.sequence_id;
            }
        }
        return best;
    }

    pub fn hostWithNewestStructuralRedo(self: *Registry) ?*Host {
        var best: ?*Host = null;
        var best_ts: u64 = 0;
        var best_seq: u64 = 0;
        for (self.hosts.items) |host| {
            const entry = host.peekStructuralRedo() orelse continue;
            if (best == null or win32_structural_history.sortsAfter(
                entry.timestamp_ms,
                entry.sequence_id,
                best_ts,
                best_seq,
            )) {
                best = host;
                best_ts = entry.timestamp_ms;
                best_seq = entry.sequence_id;
            }
        }
        return best;
    }

    pub fn findSurfaceByCore(self: *Registry, core_surface: *CoreSurface) ?*Surface {
        for (self.windows.items) |surface| {
            if (surface.core() == core_surface) return surface;
        }

        return null;
    }

    pub fn collectHostIds(self: *Registry, alloc: Allocator) !std.ArrayListUnmanaged(u32) {
        var ids: std.ArrayListUnmanaged(u32) = .empty;
        errdefer ids.deinit(alloc);
        for (self.hosts.items) |host| try ids.append(alloc, host.id);
        return ids;
    }

    pub fn collectHostSurfaces(self: *Registry, alloc: Allocator, host_id: u32) !std.ArrayListUnmanaged(*Surface) {
        var surfaces: std.ArrayListUnmanaged(*Surface) = .empty;
        errdefer surfaces.deinit(alloc);
        const host = self.findHostById(host_id) orelse return surfaces;
        for (host.tabs.items) |*tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                try surfaces.append(alloc, entry.view);
            }
        }
        return surfaces;
    }

    pub fn findTabForSurface(_: *Registry, surface: *Surface) ?struct { host: *Host, index: usize, tab: *Tab } {
        const host = surface.host orelse return null;
        for (host.tabs.items, 0..) |*tab, index| {
            if (tab.findHandle(surface) != null) {
                return .{ .host = host, .index = index, .tab = tab };
            }
        }
        return null;
    }

    pub fn focusedSurfaceForHostTab(_: *Registry, host: *Host, tab_id: u32) ?*Surface {
        for (host.tabs.items) |*tab| {
            if (tab.id != tab_id) continue;
            return tab.focusedSurface();
        }

        return null;
    }

    pub fn resolveToastActivationSurface(
        self: *Registry,
        activation: win32_toast_activation.ActivationTarget,
    ) ?*Surface {
        // Ids are this process's only when the toast is: a click on another
        // noctty's toast (COM hands it to whichever process registered the
        // activator, or to a new one after that process ended) must not
        // pick a window or tab that happens to share a number here.
        if (activation.pid != sys.GetCurrentProcessId()) return self.primarySurface();

        if (activation.surface_id) |surface_id| {
            if (self.findSurfaceById(surface_id)) |surface| {
                return surface;
            }
        }

        if (activation.window_id) |window_id| {
            if (self.findHostById(window_id)) |host| {
                if (activation.tab_id) |tab_id| {
                    if (self.focusedSurfaceForHostTab(host, tab_id)) |surface| {
                        return surface;
                    }
                }
                if (host.activeSurface()) |surface| return surface;
            }
        }

        return self.primarySurface();
    }

    pub fn removeWindow(self: *Registry, surface: *Surface) void {
        for (self.windows.items, 0..) |item, i| {
            if (item == surface) {
                _ = self.windows.swapRemove(i);
                break;
            }
        }
    }
};

/// Shared with the existing reference-removal regression test.
pub fn detachHostReference(hosts: *std.ArrayListUnmanaged(*Host), host: *Host) bool {
    for (hosts.items, 0..) |item, i| {
        if (item != host) continue;
        _ = hosts.swapRemove(i);
        return true;
    }
    return false;
}

test "Registry adds in order and removes the first match by swapping the last" {
    var registry: Registry = .{};
    defer registry.hosts.deinit(std.testing.allocator);
    defer registry.windows.deinit(std.testing.allocator);
    var hosts: [3]Host = undefined;
    var surfaces: [3]Surface = undefined;
    for (&hosts, &surfaces) |*host, *surface| {
        try registry.addHost(std.testing.allocator, host);
        try registry.addWindow(std.testing.allocator, surface);
    }
    try std.testing.expect(std.mem.eql(*Host, &.{ &hosts[0], &hosts[1], &hosts[2] }, registry.hosts.items));
    try std.testing.expect(std.mem.eql(*Surface, &.{ &surfaces[0], &surfaces[1], &surfaces[2] }, registry.windows.items));

    try std.testing.expect(registry.removeHost(&hosts[0]));
    registry.removeWindow(&surfaces[0]);
    try std.testing.expect(std.mem.eql(*Host, &.{ &hosts[2], &hosts[1] }, registry.hosts.items));
    try std.testing.expect(std.mem.eql(*Surface, &.{ &surfaces[2], &surfaces[1] }, registry.windows.items));
    try std.testing.expect(!registry.removeHost(&hosts[0]));
    registry.removeWindow(&surfaces[0]);
    try std.testing.expect(std.mem.eql(*Host, &.{ &hosts[2], &hosts[1] }, registry.hosts.items));
    try std.testing.expect(std.mem.eql(*Surface, &.{ &surfaces[2], &surfaces[1] }, registry.windows.items));

    // Duplicates are not introduced by production registration, but matching
    // the first reference is part of the original removal's identity rule.
    try registry.addHost(std.testing.allocator, &hosts[2]);
    try registry.addWindow(std.testing.allocator, &surfaces[2]);
    try std.testing.expect(registry.removeHost(&hosts[2]));
    registry.removeWindow(&surfaces[2]);
    try std.testing.expect(std.mem.eql(*Host, &.{ &hosts[2], &hosts[1] }, registry.hosts.items));
    try std.testing.expect(std.mem.eql(*Surface, &.{ &surfaces[2], &surfaces[1] }, registry.windows.items));
}

const LookupFixture = struct {
    core_app: @import("../../App.zig") = undefined,
    app: win32.App = undefined,
    first: Host = undefined,
    second: Host = undefined,
    empty: Host = undefined,
    a: Surface = undefined,
    b: Surface = undefined,
    c: Surface = undefined,
    split: Surface = undefined,
    session: win32.TestSession = .{},

    fn init(self: *LookupFixture) !void {
        try self.session.init(.{
            .core_app = &self.core_app,
            .app = &self.app,
            .hosts = &.{
                .{ .storage = &self.first, .id = 1, .register = true },
                .{ .storage = &self.second, .id = 2, .register = true },
                .{ .storage = &self.empty, .id = 3, .register = true },
            },
            .surfaces = &.{
                .{ .storage = &self.a, .host = &self.first, .register = true },
                .{ .storage = &self.b, .host = &self.first, .register = true },
                .{ .storage = &self.c, .host = &self.second, .register = true },
                .{ .storage = &self.split, .host = &self.second },
            },
            .tabs = &.{
                .{ .host = &self.first, .surface = &self.a, .id = 11 },
                .{ .host = &self.first, .surface = &self.b, .id = 12 },
                .{ .host = &self.second, .surface = &self.c, .id = 21 },
            },
        });
        errdefer self.session.deinit();
        self.a.core_surface.id = 101;
        self.b.core_surface.id = 102;
        self.c.core_surface.id = 201;
        self.split.core_surface.id = 202;
        self.first.activated = 10;
        self.second.activated = 20;
        self.empty.activated = 30;
        var inserted = try win32.SplitTreeSurface.init(std.testing.allocator, &self.split);
        defer inserted.deinit();
        const tab = &self.second.tabs.items[0];
        const tree = try tab.tree.split(std.testing.allocator, tab.focused, .right, 0.5, &inserted);
        tab.tree.deinit();
        tab.tree = tree;
        tab.focused = tab.findHandle(&self.c) orelse return error.MissingFixtureFocus;
    }

    fn deinit(self: *LookupFixture) void {
        self.session.deinit();
    }
};

test "Registry identity lookups preserve list then tab tree search and collection order" {
    var fixture: LookupFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const registry = &fixture.app.registry;
    try std.testing.expectEqual(&fixture.first, registry.findHostById(1).?);
    try std.testing.expect(registry.findHostById(99) == null);
    try std.testing.expectEqual(&fixture.a, registry.activeSurfaceForHost(1).?);
    try std.testing.expect(registry.activeSurfaceForHost(3) == null);
    try std.testing.expect(registry.activeSurfaceForHost(99) == null);
    try std.testing.expectEqual(&fixture.split, registry.findSurfaceById(202).?);
    try std.testing.expect(registry.findSurfaceById(999) == null);
    try std.testing.expectEqual(&fixture.split, registry.findLiveSurfaceById(202).?);
    try std.testing.expect(registry.findLiveSurfaceById(999) == null);
    try std.testing.expectEqual(&fixture.a, registry.findSurfaceByCore(&fixture.a.core_surface).?);
    // Core-pointer lookup intentionally consults only windows, even though
    // the id lookup finds this split in its tab tree.
    try std.testing.expect(registry.findSurfaceByCore(&fixture.split.core_surface) == null);
    const found = registry.findTabForSurface(&fixture.split).?;
    try std.testing.expectEqual(&fixture.second, found.host);
    try std.testing.expectEqual(@as(usize, 0), found.index);
    try std.testing.expectEqual(&fixture.second.tabs.items[0], found.tab);
    try std.testing.expectEqual(&fixture.b, registry.focusedSurfaceForHostTab(&fixture.first, 12).?);
    try std.testing.expect(registry.focusedSurfaceForHostTab(&fixture.first, 99) == null);

    var ids = try registry.collectHostIds(std.testing.allocator);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, ids.items);
    var surfaces = try registry.collectHostSurfaces(std.testing.allocator, 2);
    defer surfaces.deinit(std.testing.allocator);
    // SplitTree iterates node storage, which keeps the inserted leaf
    // before the original leaf for this split. Preserve that order.
    try std.testing.expectEqual(@as(usize, 2), surfaces.items.len);
    try std.testing.expect(surfaces.items[0] == &fixture.split);
    try std.testing.expect(surfaces.items[1] == &fixture.c);
    var absent = try registry.collectHostSurfaces(std.testing.allocator, 99);
    defer absent.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), absent.items.len);

    // Equal ids return the windows match before any tab-tree match.
    fixture.a.core_surface.id = 202;
    try std.testing.expectEqual(&fixture.a, registry.findSurfaceById(202).?);
    const hwnd: HWND = @ptrFromInt(0x1000);
    fixture.first.hwnd = hwnd;
    fixture.second.hwnd = hwnd;
    defer fixture.first.hwnd = null;
    defer fixture.second.hwnd = null;
    try std.testing.expectEqual(&fixture.first, registry.findHostByHwnd(hwnd).?);
    try std.testing.expect(registry.findHostByHwnd(@ptrFromInt(0x2000)) == null);
}

test "Registry removal lookups preserve tab identity until the tab itself is detached" {
    var fixture: LookupFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const registry = &fixture.app.registry;
    registry.removeWindow(&fixture.a);
    try std.testing.expectEqual(&fixture.a, registry.findSurfaceById(101).?);
    try std.testing.expectEqual(&fixture.a, registry.findLiveSurfaceById(101).?);
    try std.testing.expect(registry.findSurfaceByCore(&fixture.a.core_surface) == null);
    try std.testing.expectEqual(&fixture.first.tabs.items[0], registry.findTabForSurface(&fixture.a).?.tab);

    // App.removeHost detaches the reference before Host.deinit. A surface
    // still follows its owner while callbacks run in that teardown interval.
    try std.testing.expect(registry.removeHost(&fixture.first));
    try std.testing.expect(registry.findHostById(1) == null);
    try std.testing.expect(registry.findSurfaceById(101) == null);
    try std.testing.expectEqual(&fixture.first, registry.findTabForSurface(&fixture.a).?.host);
    // A different pane still in windows remains findable, and live, even
    // though its owner has just left hosts.
    try std.testing.expectEqual(&fixture.b, registry.findLiveSurfaceById(102).?);
    var removed = fixture.first.tabs.orderedRemove(1);
    defer removed.deinit();
    try std.testing.expectEqual(&fixture.b, registry.findSurfaceById(102).?);
    try std.testing.expect(registry.findLiveSurfaceById(102) == null);
    try std.testing.expect(registry.findTabForSurface(&fixture.b) == null);
    registry.removeWindow(&fixture.b);
    try std.testing.expect(registry.findSurfaceById(102) == null);
    // Swap removal made the retained empty host primary; do not skip it in
    // favour of the live second host.
    try std.testing.expect(registry.primarySurface() == null);
    var ids = try registry.collectHostIds(std.testing.allocator);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, &.{ 3, 2 }, ids.items);
}

test "Registry target focus and new window choices retain fallback and activation order" {
    var fixture: LookupFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const registry = &fixture.app.registry;
    try std.testing.expectEqual(&fixture.a, registry.primarySurface().?);
    try std.testing.expectEqual(&fixture.a, registry.findSurfaceForTarget(.app).?);
    try std.testing.expectEqual(&fixture.b, registry.findSurfaceForTarget(.{ .surface = &fixture.b.core_surface }).?);
    try std.testing.expect(registry.findSurfaceForTarget(.{ .surface = &fixture.split.core_surface }) == null);
    try std.testing.expect(registry.focusedSurfaceForUndoRedo() == null);
    fixture.b.window_focused = true;
    try std.testing.expectEqual(&fixture.b, registry.focusedSurfaceForUndoRedo().?);
    fixture.c.window_focused = true;
    try std.testing.expectEqual(&fixture.c, registry.focusedSurfaceForUndoRedo().?);
    fixture.a.window_focused = true;
    try std.testing.expectEqual(&fixture.a, registry.focusedSurfaceForUndoRedo().?);
    try std.testing.expectEqual(&fixture.c, registry.newWindowSource(.app).?);
    try std.testing.expectEqual(&fixture.b, registry.newWindowSource(.{ .surface = &fixture.b.core_surface }).?);
    try std.testing.expect(registry.quickTerminalHost() == null);
    fixture.second.quick_terminal = true;
    try std.testing.expectEqual(&fixture.second, registry.quickTerminalHost().?);
    try std.testing.expectEqual(&fixture.a, registry.newWindowSource(.{ .surface = &fixture.c.core_surface }).?);
    fixture.first.quick_terminal = true;
    try std.testing.expectEqual(&fixture.first, registry.quickTerminalHost().?);
    try std.testing.expect(registry.newWindowSource(.app) == null);
    try std.testing.expect(registry.removeHost(&fixture.first));
    try std.testing.expectEqual(&fixture.second, registry.quickTerminalHost().?);
    fixture.empty.quick_terminal = true;
    // Host removal swapped this zero-tab host to the front: quick-terminal
    // identity remains reachable there even while it has no active pane.
    try std.testing.expectEqual(&fixture.empty, registry.quickTerminalHost().?);
    try std.testing.expect(registry.removeHost(&fixture.empty));
    try std.testing.expectEqual(&fixture.second, registry.quickTerminalHost().?);
    fixture.b.host = null;
    try std.testing.expectEqual(&fixture.b, registry.newWindowSource(.{ .surface = &fixture.b.core_surface }).?);
    try std.testing.expect(registry.findTabForSurface(&fixture.b) == null);
}

test "Registry structural history choices keep sequence ties and empty hosts reachable" {
    var fixture: LookupFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const registry = &fixture.app.registry;
    try std.testing.expect(registry.hostWithNewestStructuralUndo() == null);
    try std.testing.expect(registry.hostWithNewestStructuralRedo() == null);
    const entries = &fixture.empty.structural_undo_entries;
    try entries.append(std.testing.allocator, .{
        .kind = .split_create,
        .timestamp_ms = 50,
        .sequence_id = 2,
        .payload = .{ .split_create = .{ .source_surface = &fixture.a, .created_surface = &fixture.b } },
    });
    try fixture.first.structural_undo_entries.append(std.testing.allocator, .{
        .kind = .split_create,
        .timestamp_ms = 50,
        .sequence_id = 1,
        .payload = .{ .split_create = .{ .source_surface = &fixture.a, .created_surface = &fixture.b } },
    });
    try std.testing.expectEqual(&fixture.empty, registry.hostWithNewestStructuralUndo().?);
    fixture.first.structural_undo_entries.items[0].sequence_id = 3;
    try std.testing.expectEqual(&fixture.first, registry.hostWithNewestStructuralUndo().?);
    fixture.first.structural_undo_entries.items[0].timestamp_ms = 49;
    try std.testing.expectEqual(&fixture.empty, registry.hostWithNewestStructuralUndo().?);
    try fixture.empty.structural_redo_entries.append(std.testing.allocator, entries.items[0]);
    try fixture.first.structural_redo_entries.append(std.testing.allocator, entries.items[0]);
    // Exact ties retain the first host; higher sequence selects the later.
    try std.testing.expectEqual(&fixture.first, registry.hostWithNewestStructuralRedo().?);
    fixture.empty.structural_redo_entries.items[0].sequence_id = 4;
    try std.testing.expectEqual(&fixture.empty, registry.hostWithNewestStructuralRedo().?);
}

test "Registry toast lookup keeps exact tab host and foreign process fallback precedence" {
    var fixture: LookupFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const registry = &fixture.app.registry;
    const pid = sys.GetCurrentProcessId();
    try std.testing.expectEqual(&fixture.split, registry.resolveToastActivationSurface(.{ .pid = pid, .surface_id = 202, .window_id = 1, .tab_id = 12 }).?);
    try std.testing.expectEqual(&fixture.b, registry.resolveToastActivationSurface(.{ .pid = pid, .surface_id = 999, .window_id = 1, .tab_id = 12 }).?);
    try std.testing.expectEqual(&fixture.c, registry.resolveToastActivationSurface(.{ .pid = pid, .window_id = 2, .tab_id = 99 }).?);
    try std.testing.expectEqual(&fixture.a, registry.resolveToastActivationSurface(.{ .pid = pid, .window_id = 99 }).?);
    try std.testing.expectEqual(&fixture.a, registry.resolveToastActivationSurface(.{ .pid = pid +% 4, .surface_id = 202 }).?);
    try std.testing.expectEqual(&fixture.a, registry.resolveToastActivationSurface(.{ .surface_id = 202 }).?);
}

test "Registry shown target and window position lookups use current native visibility" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try win32.runOnHiddenDesktop(struct {
        fn run() !void {
            var fixture: LookupFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            const registry = &fixture.app.registry;
            const first = try win32.createTestHostWindow();
            defer _ = sys.DestroyWindow(first);
            const second = try win32.createTestHostWindow();
            defer _ = sys.DestroyWindow(second);
            fixture.first.hwnd = first;
            fixture.second.hwnd = second;
            defer fixture.first.hwnd = null;
            defer fixture.second.hwnd = null;
            try std.testing.expect(registry.shownSurfaceForTarget(.app) == null);
            var rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(second, &rect) != 0);
            try std.testing.expect(!registry.windowStartsAt(rect, null));
            _ = sys.ShowWindow(second, @import("consts.zig").SW_SHOWNOACTIVATE);
            try std.testing.expectEqual(&fixture.c, registry.shownSurfaceForTarget(.app).?);
            try std.testing.expect(registry.windowStartsAt(rect, null));
            try std.testing.expect(!registry.windowStartsAt(rect, second));
            _ = sys.ShowWindow(first, @import("consts.zig").SW_SHOWNOACTIVATE);
            try std.testing.expectEqual(&fixture.a, registry.shownSurfaceForTarget(.app).?);
            try std.testing.expectEqual(&fixture.c, registry.shownSurfaceForTarget(.{ .surface = &fixture.c.core_surface }).?);
            _ = sys.ShowWindow(second, @import("consts.zig").SW_MINIMIZE);
            // Hide the other window to distinguish iconic exclusion from
            // matching its coincident default position.
            _ = sys.ShowWindow(first, @import("consts.zig").SW_HIDE);
            try std.testing.expect(!registry.windowStartsAt(rect, null));
        }
    }.run);
}
