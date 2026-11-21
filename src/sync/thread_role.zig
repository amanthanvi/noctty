//! The roles of the runtime thread-role layer (PLAN.md §2.7): which thread a
//! piece of code runs on, as the renderer-state mutex (`state_mutex.zig`)
//! reads it at each acquisition. Each thread entry enters its role at its
//! first line (`const scope = thread_role.enter(.renderer); defer
//! scope.exit();`), the UI role is entered on the first line of `main`, and a
//! test enters the role it simulates through a fixture scope.
//!
//! This module never imports `src/renderer`: lib-vt's search code reaches the
//! wrapper without the renderer. With the layer off (`layer`), every function
//! here compiles to nothing and no thread-local exists.

const std = @import("std");
const builtin = @import("builtin");

/// Which form of the layer a build gets.
pub const Layer = enum { off, on };

/// The form this build gets (§2.7's build scope: on in the app exe and the
/// test exe in Debug and ReleaseSafe, off everywhere else): the
/// `thread_roles` build option (`Config.thread_roles`), which every module
/// that compiles this file has, so a module built without it fails to
/// compile instead of guessing.
pub const layer: Layer = if (@import("build_options").thread_roles) .on else .off;

/// Whether the role policies panic: PN3 (a plain lock from `.renderer`), PN4
/// (an acquisition from a thread with no role) and PN7 (a window procedure
/// off `.ui`). False while 1A.2 gives thread entries and fixtures their
/// roles; the step that converts the renderer's plain locks deletes it
/// (RQ4). The holder's rules (PN1, PN2) and the fixture rule (PN6) hold
/// wherever the layer is on.
pub const armed = false;

/// A thread's role. `.none` is a thread that entered none.
pub const Role = union(enum) {
    none,
    ui,
    renderer,
    termio,
    reader,
    search,
    /// A named background thread (the thread-entry registry's
    /// `worker:<name>` rows). The name is a static string, for messages.
    worker: []const u8,
    test_support,

    /// The role as the thread-entry registry and the reviewed table write
    /// it: `ui`, `worker:<name>`, `none`.
    pub fn format(self: Role, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .worker => |name| try writer.print("worker:{s}", .{name}),
            else => try writer.writeAll(@tagName(self)),
        }
    }
};

/// A role scope in one form of the layer: what `exit` restores.
pub fn ScopeOf(comptime form: Layer) type {
    return switch (form) {
        // Compiles to nothing with the layer off.
        .off => struct {
            pub inline fn exit(self: @This()) void {
                _ = self;
            }
        },
        // Scopes nest; each exits in the reverse order of its entry, which
        // `depth` checks (PN6).
        .on => struct {
            previous: Role,
            /// This scope's nesting depth on its thread, from 1; 0 for an
            /// `enterIfNone` that entered nothing.
            depth: u32,
            fixture: bool,

            /// Restores the role the thread had before this scope.
            pub fn exit(self: @This()) void {
                if (self.depth == 0) return;
                if (thread_depth != self.depth) panicOutOfOrder(self.fixture, self.depth, thread_depth);
                thread_current = self.previous;
                thread_depth -= 1;
            }
        },
    };
}

/// The role API in one form of the layer. Code calls the module's own
/// functions below, which are this build's form; tests name a form to check
/// both in one build. Both forms share the one thread-local role.
pub fn Roles(comptime form: Layer) type {
    return switch (form) {
        .off => struct {
            const Self = @This();
            pub const Scope = ScopeOf(.off);

            pub inline fn current() Role {
                return .none;
            }

            pub inline fn enter(role: Role) Self.Scope {
                _ = role;
                return .{};
            }

            pub inline fn enterIfNone(role: Role) Self.Scope {
                _ = role;
                return .{};
            }

            pub inline fn fixture(role: Role) Self.Scope {
                _ = role;
                return .{};
            }

            pub inline fn assertWindowProc() void {}
        },
        .on => struct {
            const Self = @This();
            pub const Scope = ScopeOf(.on);

            /// The calling thread's role.
            pub inline fn current() Role {
                return thread_current;
            }

            /// Enters `role` on the calling thread until the scope exits,
            /// whatever role it had: a thread entry, or a helper that nests
            /// inside a role the thread already has (`Feed.run`'s `.reader`
            /// inside its test's fixture).
            pub fn enter(role: Role) Self.Scope {
                const scope: Self.Scope = .{
                    .previous = thread_current,
                    .depth = thread_depth + 1,
                    .fixture = false,
                };
                thread_current = role;
                thread_depth = scope.depth;
                return scope;
            }

            /// Enters `role` only on a thread that has none, and otherwise
            /// keeps the caller's role (RQ7: a task run inline on its caller
            /// keeps the caller's role; one a pool worker runs enters its own).
            pub fn enterIfNone(role: Role) Self.Scope {
                if (thread_current != .none) return .{
                    .previous = thread_current,
                    .depth = 0,
                    .fixture = false,
                };
                return Self.enter(role);
            }

            /// A test fixture's scope: the role the test simulates, entered
            /// on a thread that has none (PN6), and exited in order.
            pub fn fixture(role: Role) Self.Scope {
                if (thread_current != .none) panicFixtureOnRole(role, thread_current);
                var scope = Self.enter(role);
                scope.fixture = true;
                return scope;
            }

            /// PN7: a window procedure runs on the UI thread. In the test exe
            /// a thread with no role is allowed, since many tests drive a
            /// window from their own thread; PN4 still covers what it
            /// acquires.
            pub inline fn assertWindowProc() void {
                if (!armed) return;
                const role = thread_current;
                if (role == .ui) return;
                if (builtin.is_test and role == .none) return;
                panicWindowProc(role);
            }
        },
    };
}

const active = Roles(layer);

/// This build's scope type, for a fixture that holds its scope for its
/// lifetime.
pub const Scope = ScopeOf(layer);
pub const current = active.current;
pub const enter = active.enter;
pub const enterIfNone = active.enterIfNone;
pub const fixture = active.fixture;
pub const assertWindowProc = active.assertWindowProc;

// The layer's state, referenced only by the on form, so a build with the
// layer off has no thread-local.
threadlocal var thread_current: Role = .none;
threadlocal var thread_depth: u32 = 0;

fn panicFixtureOnRole(role: Role, held: Role) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: PN6 a fixture scope for role {f} entered on a thread " ++
            "whose role is {f}; a fixture enters on a thread with no role, and code " ++
            "the thread already runs nests its role with thread_role.enter",
        .{ role, held },
    );
}

fn panicOutOfOrder(is_fixture: bool, depth: u32, thread: u32) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: PN6 a {s} scope exited out of order (its depth {d}, " ++
            "the thread's {d}); scopes exit in the reverse order of their entry",
        .{ if (is_fixture) "fixture" else "role", depth, thread },
    );
}

fn panicWindowProc(role: Role) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: PN7 a window procedure on a thread whose role is {f}, " ++
            "not ui; a window runs on the UI thread, which enters .ui",
        .{role},
    );
}

const testing = std.testing;
const On = Roles(.on);

fn expectRole(expected: Role) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(On.current()));
}

test "a role scope restores the previous role, nested" {
    try expectRole(.none);
    {
        const outer = On.enter(.ui);
        defer outer.exit();
        try expectRole(.ui);
        {
            const inner = On.enter(.{ .worker = "role-test" });
            defer inner.exit();
            try expectRole(.{ .worker = "" });
            try testing.expectEqualStrings("role-test", On.current().worker);
        }
        try expectRole(.ui);
    }
    try expectRole(.none);
}

test "enterIfNone enters only on a thread with no role" {
    {
        const outer = On.enterIfNone(.search);
        defer outer.exit();
        try expectRole(.search);
        {
            const kept = On.enterIfNone(.ui);
            defer kept.exit();
            try testing.expectEqual(0, kept.depth);
            try expectRole(.search);
        }
        try expectRole(.search);
    }
    try expectRole(.none);
}

test "a fixture scope enters on a thread with no role and nests a role scope" {
    {
        const scope = On.fixture(.reader);
        defer scope.exit();
        try testing.expect(scope.fixture);
        try expectRole(.reader);
        {
            // A helper the fixture's thread runs nests as Feed.run does.
            const nested = On.enter(.reader);
            defer nested.exit();
            try testing.expect(!nested.fixture);
            try expectRole(.reader);
        }
        try expectRole(.reader);
    }
    try expectRole(.none);

    // A second fixture on the same thread, after the first exited.
    {
        const again = On.fixture(.ui);
        defer again.exit();
        try expectRole(.ui);
        On.assertWindowProc();
    }
    try expectRole(.none);
}

test "a role is the thread's own" {
    const scope = On.fixture(.ui);
    defer scope.exit();

    const Probe = struct {
        seen_first: Role = .ui,
        seen_inside: Role = .none,
        seen_last: Role = .ui,

        fn run(self: *@This()) void {
            self.seen_first = On.current();
            {
                const own = On.enter(.termio);
                defer own.exit();
                self.seen_inside = On.current();
            }
            self.seen_last = On.current();
        }
    };
    var probe: Probe = .{};
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();

    try testing.expect(probe.seen_first == .none);
    try testing.expect(probe.seen_inside == .termio);
    try testing.expect(probe.seen_last == .none);
    try expectRole(.ui);
}

test "assertWindowProc allows ui, and in a test a thread with no role" {
    On.assertWindowProc();
    const scope = On.enter(.ui);
    defer scope.exit();
    On.assertWindowProc();
}

test "the off form has the same API and keeps no role" {
    const Off = Roles(.off);
    try testing.expectEqual(0, @sizeOf(Off.Scope));
    const scope = Off.fixture(.reader);
    defer scope.exit();
    try testing.expect(Off.current() == .none);
    const nested = Off.enter(.{ .worker = "off" });
    nested.exit();
    const maybe = Off.enterIfNone(.search);
    maybe.exit();
    Off.assertWindowProc();
    // The off form leaves the thread-local alone.
    try expectRole(.none);
}

test "a role prints as the registry writes it" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("renderer", try std.fmt.bufPrint(&buf, "{f}", .{@as(Role, .renderer)}));
    try testing.expectEqualStrings("none", try std.fmt.bufPrint(&buf, "{f}", .{@as(Role, .none)}));
    try testing.expectEqualStrings(
        "worker:update-check",
        try std.fmt.bufPrint(&buf, "{f}", .{Role{ .worker = "update-check" }}),
    );
    try testing.expectEqualStrings("test_support", try std.fmt.bufPrint(&buf, "{f}", .{@as(Role, .test_support)}));
}
