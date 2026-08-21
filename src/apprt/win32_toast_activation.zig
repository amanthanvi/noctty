//! Launch-argument parsing for Windows Action Center toast activation.
//!
//! When a user clicks a toast notification, Windows activates the
//! registered AUMID process with a launch string pulled from the
//! toast XML's `<toast launch="...">` attribute.
//!
//! Format: `wgh://activate?surface={id}&tab={id}&window={id}&action={action}`
//!
//! This module is pure parsing with no Win32 API dependency. `win32.zig`
//! owns argv scanning and App dispatch.

const std = @import("std");
const Allocator = std.mem.Allocator;

const scheme = "wgh://activate?";

pub const Action = enum {
    focus,

    fn fromString(s: []const u8) ?Action {
        if (std.mem.eql(u8, s, "focus")) return .focus;
        return null;
    }

    fn toString(self: Action) []const u8 {
        return switch (self) {
            .focus => "focus",
        };
    }
};

pub const ActivationTarget = struct {
    surface_id: ?u64 = null,
    tab_id: ?u32 = null,
    window_id: ?u32 = null,
    action: ?Action = null,

    pub fn eql(self: ActivationTarget, other: ActivationTarget) bool {
        return self.surface_id == other.surface_id and
            self.tab_id == other.tab_id and
            self.window_id == other.window_id and
            self.action == other.action;
    }
};

pub const ParseError = error{
    InvalidScheme,
    InvalidNumber,
    Empty,
    Malformed,
};

pub const ScanLaunchArgsResult = union(enum) {
    none,
    malformed,
    activation: ActivationTarget,
};

/// Parse a `wgh://activate?key=val&...` launch string into an ActivationTarget.
pub fn parseLaunchArg(launch: []const u8) ParseError!ActivationTarget {
    if (launch.len == 0) return error.Empty;
    if (!std.mem.startsWith(u8, launch, scheme)) return error.InvalidScheme;

    const query = launch[scheme.len..];
    if (query.len == 0) return .{};

    var target = ActivationTarget{};
    var pairs = std.mem.splitScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        if (pair.len == 0) return error.Malformed;

        const sep_pos = std.mem.indexOfScalar(u8, pair, '=') orelse return error.Malformed;
        const key = pair[0..sep_pos];
        const val = pair[sep_pos + 1 ..];

        if (key.len == 0) return error.Malformed;

        if (std.mem.eql(u8, key, "surface")) {
            target.surface_id = std.fmt.parseInt(u64, val, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, key, "tab")) {
            target.tab_id = std.fmt.parseInt(u32, val, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, key, "window")) {
            target.window_id = std.fmt.parseInt(u32, val, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, key, "action")) {
            target.action = Action.fromString(val);
            // Unknown action tokens are ignored for forward compatibility.
        }
        // Unknown keys are ignored for forward compatibility.
    }

    return target;
}

/// Scan argv-like input for the first toast activation argument.
/// Returns null when absent or malformed.
pub fn scanLaunchArgs(args: []const []const u8) ?ActivationTarget {
    return switch (scanLaunchArgsDetailed(args)) {
        .none, .malformed => null,
        .activation => |target| target,
    };
}

/// Scan argv-like input for the first toast activation argument.
/// Returns an explicit malformed tag so callers can swallow bad
/// activation argv instead of misrouting it into startup arg parsing.
pub fn scanLaunchArgsDetailed(args: []const []const u8) ScanLaunchArgsResult {
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, scheme)) continue;
        return .{
            .activation = parseLaunchArg(arg) catch return .malformed,
        };
    }

    return .none;
}

/// Build a `wgh://activate?...` launch string from an ActivationTarget.
/// Caller owns the returned slice. Omits null fields.
pub fn buildLaunchArg(alloc: Allocator, target: ActivationTarget) Allocator.Error![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, scheme);

    var first = true;

    if (target.surface_id) |id| {
        try appendSep(&buf, alloc, &first);
        try buf.appendSlice(alloc, "surface=");
        try appendInt(u64, &buf, alloc, id);
    }
    if (target.tab_id) |id| {
        try appendSep(&buf, alloc, &first);
        try buf.appendSlice(alloc, "tab=");
        try appendInt(u32, &buf, alloc, id);
    }
    if (target.window_id) |id| {
        try appendSep(&buf, alloc, &first);
        try buf.appendSlice(alloc, "window=");
        try appendInt(u32, &buf, alloc, id);
    }
    if (target.action) |a| {
        try appendSep(&buf, alloc, &first);
        try buf.appendSlice(alloc, "action=");
        try buf.appendSlice(alloc, a.toString());
    }

    return buf.toOwnedSlice(alloc);
}

fn appendSep(buf: *std.ArrayListUnmanaged(u8), alloc: Allocator, first: *bool) Allocator.Error!void {
    if (!first.*) try buf.append(alloc, '&');
    first.* = false;
}

fn appendInt(comptime T: type, buf: *std.ArrayListUnmanaged(u8), alloc: Allocator, val: T) Allocator.Error!void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch unreachable;
    try buf.appendSlice(alloc, s);
}

test "parse surface only" {
    const t = try parseLaunchArg("wgh://activate?surface=42");
    try std.testing.expectEqual(@as(?u64, 42), t.surface_id);
    try std.testing.expectEqual(@as(?u32, null), t.tab_id);
    try std.testing.expectEqual(@as(?u32, null), t.window_id);
    try std.testing.expectEqual(@as(?Action, null), t.action);
}

test "parse all fields" {
    const t = try parseLaunchArg("wgh://activate?tab=1&window=2&action=focus");
    try std.testing.expectEqual(@as(?u32, 1), t.tab_id);
    try std.testing.expectEqual(@as(?u32, 2), t.window_id);
    try std.testing.expectEqual(@as(?Action, .focus), t.action);
    try std.testing.expectEqual(@as(?u64, null), t.surface_id);
}

test "parse unknown key ignored (forward-compat)" {
    const t = try parseLaunchArg("wgh://activate?surface=1&foo=bar");
    try std.testing.expectEqual(@as(?u64, 1), t.surface_id);
}

test "parse invalid number" {
    const result = parseLaunchArg("wgh://activate?surface=abc");
    try std.testing.expectError(error.InvalidNumber, result);
}

test "parse empty input" {
    const result = parseLaunchArg("");
    try std.testing.expectError(error.Empty, result);
}

test "parse wrong scheme" {
    const result = parseLaunchArg("wgh://other?surface=1");
    try std.testing.expectError(error.InvalidScheme, result);
}

test "round-trip build then parse" {
    const original = ActivationTarget{
        .surface_id = 999,
        .tab_id = 7,
        .window_id = 3,
        .action = .focus,
    };

    const built = try buildLaunchArg(std.testing.allocator, original);
    defer std.testing.allocator.free(built);

    const parsed = try parseLaunchArg(built);
    try std.testing.expect(original.eql(parsed));
}

test "build omits null fields" {
    const target = ActivationTarget{ .tab_id = 5 };
    const built = try buildLaunchArg(std.testing.allocator, target);
    defer std.testing.allocator.free(built);

    try std.testing.expectEqualStrings("wgh://activate?tab=5", built);
}

test "parse malformed missing equals" {
    const result = parseLaunchArg("wgh://activate?noequals");
    try std.testing.expectError(error.Malformed, result);
}

test "scan launch args finds activation among startup argv" {
    const args = [_][]const u8{
        "--working-directory=C:/Users/amant",
        "wgh://activate?surface=77&window=5&action=focus",
        "--title=Build",
    };

    const target = scanLaunchArgs(&args).?;
    try std.testing.expectEqual(@as(?u64, 77), target.surface_id);
    try std.testing.expectEqual(@as(?u32, 5), target.window_id);
    try std.testing.expectEqual(@as(?Action, .focus), target.action);
}

test "scan launch args ignores malformed activation values" {
    const args = [_][]const u8{
        "--working-directory=C:/Users/amant",
        "wgh://activate?surface=abc",
        "--title=Build",
    };

    try std.testing.expect(scanLaunchArgs(&args) == null);
}

test "scan launch args detailed reports malformed activation" {
    const args = [_][]const u8{
        "--working-directory=C:/Users/amant",
        "wgh://activate?surface=abc",
        "--title=Build",
    };

    try std.testing.expect(scanLaunchArgsDetailed(&args) == .malformed);
}

test "scan launch args ignores non-activation wgh urls" {
    const args = [_][]const u8{
        "wgh://open?surface=abc",
        "--working-directory=C:/Users/amant",
        "wgh://activate?surface=88",
    };

    const target = scanLaunchArgs(&args).?;
    try std.testing.expectEqual(@as(?u64, 88), target.surface_id);
}

fn fuzzActivationParser(_: void, data: []const u8) !void {
    if (parseLaunchArg(data)) |target| {
        const rebuilt = try buildLaunchArg(std.testing.allocator, target);
        defer std.testing.allocator.free(rebuilt);
        try std.testing.expect(target.eql(try parseLaunchArg(rebuilt)));
    } else |err| {
        switch (err) {
            error.InvalidScheme,
            error.InvalidNumber,
            error.Empty,
            error.Malformed,
            => {},
        }
        if (data.len == 0) {
            try std.testing.expectEqual(error.Empty, err);
        } else if (!std.mem.startsWith(u8, data, scheme)) {
            try std.testing.expectEqual(error.InvalidScheme, err);
        }
    }
}

test "fuzz win32 toast activation parser" {
    try std.testing.fuzz({}, fuzzActivationParser, .{ .corpus = &.{
        "wgh://activate?surface=42&window=7&action=focus",
        "wgh://activate?surface=not-a-number",
        "wgh://other?surface=1",
    } });
}
