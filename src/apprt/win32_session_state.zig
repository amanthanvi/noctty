//! Windows session-state schema.
//!
//! Persists layout, working-directory, profile, explicit title overrides, and
//! optional bounded plain-text pane snapshots. Runtime child process state is
//! deliberately excluded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const paste_protection = @import("win32_paste_protection.zig");

pub const current_schema_version: u32 = 1;
pub const max_scrollback_lines: usize = 10_000;
pub const max_scrollback_line_bytes: usize = 16 * 1024;
/// Maximum conservative encoded-JSON storage charged to all pane snapshots.
pub const max_total_scrollback_bytes: usize = 512 * 1024;
pub const scrollback_snapshot_storage_overhead: usize = 96;

pub const ValidationError = error{
    UnsupportedVersion,
    EmptyTabs,
    EmptyLayout,
    InvalidRootNode,
    InvalidSelectedTab,
    InvalidSelectedLeaf,
    InvalidNodeIndex,
    InvalidTreeShape,
    InvalidSplitRatio,
    InvalidWindowRect,
    InvalidPaneText,
    UnreachableNode,
    TooManySessionLayoutNodes,
    TooManyScrollbackLines,
    ScrollbackLineTooLong,
    ScrollbackBudgetExceeded,
};

pub const ValidateError = ValidationError || Allocator.Error;

const VersionHeader = struct {
    schema_version: u32,
};

/// Named layouts share the session schema but treat window placement as
/// opaque input. Decode those fields as arbitrary JSON so stale state names
/// or mistyped geometry cannot reject an otherwise valid layout shape, while
/// keeping every non-placement field strict.
const LayoutState = struct {
    schema_version: u32 = current_schema_version,
    windows: []const LayoutWindow = &.{},
};

const LayoutWindow = struct {
    x: std.json.Value = .null,
    y: std.json.Value = .null,
    width: std.json.Value = .null,
    height: std.json.Value = .null,
    state: std.json.Value = .null,
    selected_tab: usize,
    tabs: []const Tab = &.{},
};

const VisitFrame = struct {
    index: usize,
    expanded: bool,
};

const ValidationPurpose = enum {
    encode,
    load,
};

pub const SessionState = struct {
    schema_version: u32 = current_schema_version,
    windows: []const Window = &.{},
};

pub const Window = struct {
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?i32 = null,
    height: ?i32 = null,
    state: ?WindowState = null,
    selected_tab: usize,
    tabs: []const Tab = &.{},
};

pub const WindowState = enum {
    normal,
    maximized,
};

pub const Tab = struct {
    selected_leaf: usize,
    layout: LayoutTree,
};

pub const LayoutTree = struct {
    root: u16,
    nodes: []const Node = &.{},
};

pub const Node = union(enum) {
    pane: Pane,
    split: Split,
};

pub const Pane = struct {
    cwd: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    title_override: ?[]const u8 = null,
    tab_title_override: ?[]const u8 = null,
    scrollback: ?ScrollbackSnapshot = null,
};

pub const ScrollbackSnapshot = struct {
    captured_at_unix_ms: u64,
    lines: []const []const u8 = &.{},
};

pub const Split = struct {
    axis: Axis,
    ratio: f32,
    first: u16,
    second: u16,
};

pub const Axis = enum {
    horizontal,
    vertical,
};

pub fn encodeAlloc(alloc: Allocator, state: SessionState) ![]u8 {
    try validateAllocForPurpose(alloc, state, .encode);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try std.json.Stringify.value(state, .{
        .whitespace = .minified,
        .emit_null_optional_fields = false,
    }, &out.writer);

    return try out.toOwnedSlice();
}

pub fn parseAlloc(alloc: Allocator, raw: []const u8) !std.json.Parsed(SessionState) {
    return parseAllocMode(alloc, raw, false);
}

/// Parse a named layout. Layouts intentionally carry only window shape, so
/// discard placement before validation; incomplete or stale geometry must not
/// quarantine an otherwise valid hand-authored or synced layout.
pub fn parseLayoutAlloc(alloc: Allocator, raw: []const u8) !std.json.Parsed(SessionState) {
    return parseAllocMode(alloc, raw, true);
}

fn parseAllocMode(
    alloc: Allocator,
    raw: []const u8,
    comptime strip_placement: bool,
) !std.json.Parsed(SessionState) {
    var header = try std.json.parseFromSlice(VersionHeader, alloc, raw, .{
        .ignore_unknown_fields = true,
    });
    defer header.deinit();

    if (header.value.schema_version != current_schema_version) {
        return error.UnsupportedVersion;
    }

    if (strip_placement) {
        var layout = try std.json.parseFromSlice(LayoutState, alloc, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
        });
        errdefer layout.deinit();

        const windows = try layout.arena.allocator().alloc(Window, layout.value.windows.len);
        for (layout.value.windows, windows) |source, *window| {
            window.* = .{
                .selected_tab = source.selected_tab,
                .tabs = source.tabs,
            };
        }

        const parsed: std.json.Parsed(SessionState) = .{
            .arena = layout.arena,
            .value = .{
                .schema_version = layout.value.schema_version,
                .windows = windows,
            },
        };
        try validateAlloc(alloc, parsed.value);
        return parsed;
    }

    var parsed = try std.json.parseFromSlice(SessionState, alloc, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    errdefer parsed.deinit();

    var scrollback_bytes: usize = 0;
    for (parsed.value.windows) |window| {
        for (window.tabs) |tab| {
            for (@constCast(tab.layout.nodes)) |*node| {
                switch (node.*) {
                    .pane => |*pane| validatePaneScrollback(
                        pane.*,
                        &scrollback_bytes,
                    ) catch {
                        pane.scrollback = null;
                    },
                    .split => {},
                }
            }
        }
    }

    try validateAlloc(alloc, parsed.value);
    return parsed;
}

pub fn validateAlloc(alloc: Allocator, state: SessionState) ValidateError!void {
    return validateAllocForPurpose(alloc, state, .load);
}

fn validateAllocForPurpose(
    alloc: Allocator,
    state: SessionState,
    purpose: ValidationPurpose,
) ValidateError!void {
    if (state.schema_version != current_schema_version) {
        return error.UnsupportedVersion;
    }

    var scrollback_bytes: usize = 0;
    for (state.windows) |window| {
        try validateWindowRect(window);
        if (window.tabs.len == 0) return error.EmptyTabs;
        if (window.selected_tab >= window.tabs.len) return error.InvalidSelectedTab;

        for (window.tabs) |tab| {
            const leaf_count = try validateLayoutTree(
                alloc,
                tab.layout,
                &scrollback_bytes,
                purpose,
            );
            if (tab.selected_leaf >= leaf_count) return error.InvalidSelectedLeaf;
        }
    }
}

fn validateWindowRect(window: Window) ValidationError!void {
    const present_count =
        @as(usize, @intFromBool(window.x != null)) +
        @as(usize, @intFromBool(window.y != null)) +
        @as(usize, @intFromBool(window.width != null)) +
        @as(usize, @intFromBool(window.height != null));
    if (present_count != 0 and present_count != 4) return error.InvalidWindowRect;
    if (window.width) |width| {
        if (width <= 0) return error.InvalidWindowRect;
    }
    if (window.height) |height| {
        if (height <= 0) return error.InvalidWindowRect;
    }
}

fn validateLayoutTree(
    alloc: Allocator,
    layout: LayoutTree,
    scrollback_bytes: *usize,
    purpose: ValidationPurpose,
) ValidateError!usize {
    if (layout.nodes.len == 0) return error.EmptyLayout;
    if (layout.nodes.len > std.math.maxInt(u16)) return error.TooManySessionLayoutNodes;

    const root_index: usize = layout.root;
    if (root_index >= layout.nodes.len) return error.InvalidRootNode;

    const visited = try alloc.alloc(u8, layout.nodes.len);
    defer alloc.free(visited);
    @memset(visited, 0);

    const stack = try alloc.alloc(VisitFrame, layout.nodes.len);
    defer alloc.free(stack);

    stack[0] = .{ .index = root_index, .expanded = false };

    var stack_len: usize = 1;
    var leaf_count: usize = 0;

    while (stack_len > 0) {
        var frame = &stack[stack_len - 1];

        if (visited[frame.index] != 0) {
            if (!frame.expanded or visited[frame.index] != 1) return error.InvalidTreeShape;
            visited[frame.index] = 2;
            stack_len -= 1;
            continue;
        }

        visited[frame.index] = 1;
        frame.expanded = true;

        switch (layout.nodes[frame.index]) {
            .pane => |pane| {
                try validatePaneScrollback(pane, scrollback_bytes);
                if (purpose == .load) try validatePane(pane);
                visited[frame.index] = 2;
                leaf_count += 1;
                stack_len -= 1;
            },
            .split => |split| {
                if (!std.math.isFinite(split.ratio) or split.ratio < 0 or split.ratio > 1) {
                    return error.InvalidSplitRatio;
                }

                const first_index: usize = split.first;
                const second_index: usize = split.second;
                if (first_index >= layout.nodes.len or second_index >= layout.nodes.len) {
                    return error.InvalidNodeIndex;
                }
                if (stack_len + 2 > stack.len) {
                    return error.InvalidTreeShape;
                }

                stack[stack_len] = .{ .index = second_index, .expanded = false };
                stack_len += 1;
                stack[stack_len] = .{ .index = first_index, .expanded = false };
                stack_len += 1;
            },
        }
    }

    if (leaf_count == 0) return error.EmptyLayout;

    for (visited) |seen| {
        if (seen == 0) return error.UnreachableNode;
    }

    return leaf_count;
}

fn validatePaneScrollback(pane: Pane, total_bytes: *usize) ValidationError!void {
    const snapshot = pane.scrollback orelse return;
    if (snapshot.lines.len > max_scrollback_lines) return error.TooManyScrollbackLines;

    var snapshot_bytes = scrollback_snapshot_storage_overhead;
    for (snapshot.lines) |line| {
        if (line.len > max_scrollback_line_bytes) return error.ScrollbackLineTooLong;
        const line_bytes = scrollbackLineStorageBytes(line) orelse
            return error.ScrollbackBudgetExceeded;
        if (line_bytes > max_total_scrollback_bytes -| snapshot_bytes) {
            return error.ScrollbackBudgetExceeded;
        }
        snapshot_bytes += line_bytes;
    }

    if (snapshot_bytes > max_total_scrollback_bytes -| total_bytes.*) {
        return error.ScrollbackBudgetExceeded;
    }
    total_bytes.* += snapshot_bytes;
}

/// Conservative JSON storage charge for one persisted line, including quotes
/// and a delimiter. This is shared by capture and schema validation so a file
/// written within the budget also fits the persistence read allowance.
pub fn scrollbackLineStorageBytes(line: []const u8) ?usize {
    var bytes: usize = 3;
    for (line) |byte| {
        const encoded: usize = if (byte < 0x20)
            switch (byte) {
                '\x08', '\x0c', '\n', '\r', '\t' => 2,
                else => 6,
            }
        else switch (byte) {
            '"', '\\' => 2,
            else => 1,
        };
        bytes = std.math.add(usize, bytes, encoded) catch return null;
    }
    return bytes;
}

fn validatePane(pane: Pane) ValidationError!void {
    for ([_]?[]const u8{
        pane.cwd,
        pane.profile,
        pane.title_override,
        pane.tab_title_override,
    }) |value| {
        if (value) |text| {
            if (!isValidPaneText(text)) return error.InvalidPaneText;
        }
    }
}

pub fn isValidPaneText(text: []const u8) bool {
    return !paste_protection.hasControlChars(text) and
        !paste_protection.hasNewline(text);
}

fn expectSessionStateEqual(expected: SessionState, actual: SessionState) !void {
    try std.testing.expectEqual(expected.schema_version, actual.schema_version);
    try std.testing.expectEqual(expected.windows.len, actual.windows.len);

    for (expected.windows, actual.windows) |expected_window, actual_window| {
        try std.testing.expectEqual(expected_window.x, actual_window.x);
        try std.testing.expectEqual(expected_window.y, actual_window.y);
        try std.testing.expectEqual(expected_window.width, actual_window.width);
        try std.testing.expectEqual(expected_window.height, actual_window.height);
        try std.testing.expectEqual(expected_window.state, actual_window.state);
        try std.testing.expectEqual(expected_window.selected_tab, actual_window.selected_tab);
        try std.testing.expectEqual(expected_window.tabs.len, actual_window.tabs.len);

        for (expected_window.tabs, actual_window.tabs) |expected_tab, actual_tab| {
            try std.testing.expectEqual(expected_tab.selected_leaf, actual_tab.selected_leaf);
            try std.testing.expectEqual(expected_tab.layout.root, actual_tab.layout.root);
            try std.testing.expectEqual(expected_tab.layout.nodes.len, actual_tab.layout.nodes.len);

            for (expected_tab.layout.nodes, actual_tab.layout.nodes) |expected_node, actual_node| {
                try expectNodeEqual(expected_node, actual_node);
            }
        }
    }
}

fn expectNodeEqual(expected: Node, actual: Node) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));

    switch (expected) {
        .pane => |expected_pane| {
            const actual_pane = actual.pane;
            try expectOptionalStringEqual(expected_pane.cwd, actual_pane.cwd);
            try expectOptionalStringEqual(expected_pane.profile, actual_pane.profile);
            try expectOptionalStringEqual(expected_pane.title_override, actual_pane.title_override);
            try expectOptionalStringEqual(expected_pane.tab_title_override, actual_pane.tab_title_override);
            try expectOptionalScrollbackEqual(expected_pane.scrollback, actual_pane.scrollback);
        },
        .split => |expected_split| {
            const actual_split = actual.split;
            try std.testing.expectEqual(expected_split.axis, actual_split.axis);
            try std.testing.expectEqual(expected_split.ratio, actual_split.ratio);
            try std.testing.expectEqual(expected_split.first, actual_split.first);
            try std.testing.expectEqual(expected_split.second, actual_split.second);
        },
    }
}

fn expectOptionalStringEqual(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |expected_value| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(expected_value, actual.?);
        return;
    }

    try std.testing.expect(actual == null);
}

fn expectOptionalScrollbackEqual(
    expected: ?ScrollbackSnapshot,
    actual: ?ScrollbackSnapshot,
) !void {
    if (expected) |expected_value| {
        try std.testing.expect(actual != null);
        const actual_value = actual.?;
        try std.testing.expectEqual(
            expected_value.captured_at_unix_ms,
            actual_value.captured_at_unix_ms,
        );
        try std.testing.expectEqual(expected_value.lines.len, actual_value.lines.len);
        for (expected_value.lines, actual_value.lines) |expected_line, actual_line| {
            try std.testing.expectEqualStrings(expected_line, actual_line);
        }
        return;
    }

    try std.testing.expect(actual == null);
}

fn encodeTestPane(pane: Pane) ![]u8 {
    const nodes = [_]Node{.{ .pane = pane }};
    const tabs = [_]Tab{.{
        .selected_leaf = 0,
        .layout = .{ .root = 0, .nodes = &nodes },
    }};
    const windows = [_]Window{.{ .selected_tab = 0, .tabs = &tabs }};
    return encodeAlloc(std.testing.allocator, .{ .windows = &windows });
}

test "win32 session state round-trips split layout metadata" {
    const left: Pane = .{
        .cwd = "C:\\src\\noctty",
        .profile = "pwsh",
        .title_override = "Build",
        .tab_title_override = "Docs",
    };
    const right: Pane = .{
        .cwd = "C:\\logs",
        .profile = "cmd.exe",
    };
    const nodes = [_]Node{
        .{ .split = .{
            .axis = .horizontal,
            .ratio = 0.5,
            .first = 1,
            .second = 2,
        } },
        .{ .pane = left },
        .{ .pane = right },
    };
    const tabs = [_]Tab{
        .{
            .selected_leaf = 1,
            .layout = .{
                .root = 0,
                .nodes = &nodes,
            },
        },
    };
    const windows = [_]Window{
        .{
            .selected_tab = 0,
            .tabs = &tabs,
        },
    };
    const state: SessionState = .{
        .windows = &windows,
    };

    const encoded = try encodeAlloc(std.testing.allocator, state);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"windows\":[{\"selected_tab\":0,\"tabs\":[{\"selected_leaf\":1,\"layout\":{\"root\":0,\"nodes\":[{\"split\":{\"axis\":\"horizontal\",\"ratio\":0.5,\"first\":1,\"second\":2}},{\"pane\":{\"cwd\":\"C:\\\\src\\\\noctty\",\"profile\":\"pwsh\",\"title_override\":\"Build\",\"tab_title_override\":\"Docs\"}},{\"pane\":{\"cwd\":\"C:\\\\logs\",\"profile\":\"cmd.exe\"}}]}}]}]}",
        encoded,
    );

    var parsed = try parseAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();

    try expectSessionStateEqual(state, parsed.value);
}

test "win32 session state round-trips pane scrollback snapshot" {
    const lines = [_][]const u8{
        "plain output",
        "tab\tseparated",
        "colors are not serialized",
    };
    const pane: Pane = .{
        .cwd = "C:\\src\\noctty",
        .scrollback = .{
            .captured_at_unix_ms = 1_777_777_777_123,
            .lines = &lines,
        },
    };

    const encoded = try encodeTestPane(pane);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"scrollback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\\u001b") == null);

    var parsed = try parseAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();
    const actual = parsed.value.windows[0].tabs[0].layout.nodes[0].pane;
    try expectOptionalScrollbackEqual(pane.scrollback, actual.scrollback);
    const parsed_line = actual.scrollback.?.lines[0];
    const encoded_start = @intFromPtr(encoded.ptr);
    const parsed_start = @intFromPtr(parsed_line.ptr);
    try std.testing.expect(parsed_start < encoded_start or parsed_start >= encoded_start + encoded.len);
}

test "win32 session state enforces scrollback line and byte caps" {
    const too_many_lines = [_][]const u8{"x"} ** (max_scrollback_lines + 1);
    try std.testing.expectError(
        error.TooManyScrollbackLines,
        encodeTestPane(.{ .scrollback = .{
            .captured_at_unix_ms = 1,
            .lines = &too_many_lines,
        } }),
    );

    const long_line = try std.testing.allocator.alloc(u8, max_scrollback_line_bytes + 1);
    defer std.testing.allocator.free(long_line);
    @memset(long_line, 'x');
    try std.testing.expectError(
        error.ScrollbackLineTooLong,
        encodeTestPane(.{ .scrollback = .{
            .captured_at_unix_ms = 2,
            .lines = &.{long_line},
        } }),
    );
    const budget_line = try std.testing.allocator.alloc(u8, max_scrollback_line_bytes);
    defer std.testing.allocator.free(budget_line);
    @memset(budget_line, '\\');
    const budget_line_count = max_total_scrollback_bytes /
        (scrollbackLineStorageBytes(budget_line).? + 1) + 1;
    const budget_lines = try std.testing.allocator.alloc([]const u8, budget_line_count);
    defer std.testing.allocator.free(budget_lines);
    @memset(budget_lines, budget_line);
    try std.testing.expectError(
        error.ScrollbackBudgetExceeded,
        encodeTestPane(.{ .scrollback = .{
            .captured_at_unix_ms = 3,
            .lines = budget_lines,
        } }),
    );
}

test "win32 session state load drops invalid pane scrollback without losing split layout" {
    const long_line = try std.testing.allocator.alloc(u8, max_scrollback_line_bytes + 1);
    defer std.testing.allocator.free(long_line);
    @memset(long_line, 'x');

    const nodes = [_]Node{
        .{ .split = .{
            .axis = .horizontal,
            .ratio = 0.5,
            .first = 1,
            .second = 2,
        } },
        .{ .pane = .{ .scrollback = .{
            .captured_at_unix_ms = 2,
            .lines = &.{long_line},
        } } },
        .{ .pane = .{ .cwd = "C:\\layout-survives" } },
    };
    const tabs = [_]Tab{.{
        .selected_leaf = 1,
        .layout = .{ .root = 0, .nodes = &nodes },
    }};
    const windows = [_]Window{.{ .selected_tab = 0, .tabs = &tabs }};

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(SessionState{ .windows = &windows }, .{
        .whitespace = .minified,
        .emit_null_optional_fields = false,
    }, &out.writer);
    const raw = try out.toOwnedSlice();
    defer std.testing.allocator.free(raw);

    var parsed = try parseAlloc(std.testing.allocator, raw);
    defer parsed.deinit();
    const parsed_tab = parsed.value.windows[0].tabs[0];
    try std.testing.expectEqual(@as(usize, 3), parsed_tab.layout.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), parsed_tab.selected_leaf);
    try std.testing.expectEqual(Axis.horizontal, parsed_tab.layout.nodes[0].split.axis);
    try std.testing.expect(parsed_tab.layout.nodes[1].pane.scrollback == null);
    try std.testing.expectEqualStrings(
        "C:\\layout-survives",
        parsed_tab.layout.nodes[2].pane.cwd.?,
    );
}

test "win32 session state omits unset optional pane metadata" {
    const nodes = [_]Node{
        .{ .pane = .{ .cwd = "C:\\src\\noctty" } },
    };
    const tabs = [_]Tab{
        .{
            .selected_leaf = 0,
            .layout = .{
                .root = 0,
                .nodes = &nodes,
            },
        },
    };
    const windows = [_]Window{
        .{
            .selected_tab = 0,
            .tabs = &tabs,
        },
    };
    const state: SessionState = .{
        .windows = &windows,
    };

    const encoded = try encodeAlloc(std.testing.allocator, state);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"profile\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"title_override\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"tab_title_override\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"scrollback\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"contents\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "null") == null);
}

test "win32 session state round-trips window geometry" {
    const nodes = [_]Node{
        .{ .pane = .{} },
    };
    const tabs = [_]Tab{
        .{
            .selected_leaf = 0,
            .layout = .{
                .root = 0,
                .nodes = &nodes,
            },
        },
    };
    const windows = [_]Window{
        .{
            .x = 10,
            .y = 20,
            .width = 1280,
            .height = 720,
            .state = .maximized,
            .selected_tab = 0,
            .tabs = &tabs,
        },
    };
    const state: SessionState = .{
        .windows = &windows,
    };

    const encoded = try encodeAlloc(std.testing.allocator, state);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"windows\":[{\"x\":10,\"y\":20,\"width\":1280,\"height\":720,\"state\":\"maximized\",\"selected_tab\":0,\"tabs\":[{\"selected_leaf\":0,\"layout\":{\"root\":0,\"nodes\":[{\"pane\":{}}]}}]}]}",
        encoded,
    );

    var parsed = try parseAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();

    try expectSessionStateEqual(state, parsed.value);
}

test "win32 session state rejects incomplete window geometry" {
    const raw =
        \\{"schema_version":1,"windows":[{"x":10,"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{}}]}}]}]}
    ;

    try std.testing.expectError(error.InvalidWindowRect, parseAlloc(std.testing.allocator, raw));
}

test "win32 session state rejects non-positive window geometry" {
    const raw =
        \\{"schema_version":1,"windows":[{"x":10,"y":20,"width":0,"height":720,"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{}}]}}]}]}
    ;

    try std.testing.expectError(error.InvalidWindowRect, parseAlloc(std.testing.allocator, raw));
}

test "win32 named layout parsing strips placement before validation" {
    const cases = [_][]const u8{
        \\{"schema_version":1,"windows":[{"x":10,"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{}}]}}]}]}
        ,
        \\{"schema_version":1,"windows":[{"x":10,"y":20,"width":0,"height":720,"state":"maximized","selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{}}]}}]}]}
        ,
        \\{"schema_version":1,"windows":[{"x":"stale","y":{"monitor":2},"width":[],"height":false,"state":"minimized","selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{}}]}}]}]}
        ,
    };

    for (cases) |raw| {
        var parsed = try parseLayoutAlloc(std.testing.allocator, raw);
        defer parsed.deinit();
        const window = parsed.value.windows[0];
        try std.testing.expect(window.x == null);
        try std.testing.expect(window.y == null);
        try std.testing.expect(window.width == null);
        try std.testing.expect(window.height == null);
        try std.testing.expect(window.state == null);
    }
}

test "win32 named layout parsing stays strict outside placement" {
    const raw =
        \\{"schema_version":1,"windows":[{"future_placement":true,"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{}}]}}]}]}
    ;

    try std.testing.expectError(
        error.UnknownField,
        parseLayoutAlloc(std.testing.allocator, raw),
    );
}

test "win32 session state parse rejects unsupported schema version" {
    const raw =
        \\{"schema_version":9,"windows":[]}
    ;

    try std.testing.expectError(
        error.UnsupportedVersion,
        parseAlloc(std.testing.allocator, raw),
    );
}

test "win32 session state parse requires explicit schema version" {
    const raw =
        \\{"windows":[]}
    ;

    try std.testing.expectError(
        error.MissingField,
        parseAlloc(std.testing.allocator, raw),
    );
}

test "win32 session state parse requires explicit selected_tab" {
    const raw =
        \\{"schema_version":1,"windows":[{"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\src\\noctty"}}]}}]}]}
    ;

    try std.testing.expectError(
        error.MissingField,
        parseAlloc(std.testing.allocator, raw),
    );
}

test "win32 session state parse requires explicit selected_leaf" {
    const raw =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\src\\noctty"}}]}}]}]}
    ;

    try std.testing.expectError(
        error.MissingField,
        parseAlloc(std.testing.allocator, raw),
    );
}

test "win32 session state parse requires explicit layout root" {
    const raw =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"nodes":[{"pane":{"cwd":"C:\\src\\noctty"}}]}}]}]}
    ;

    try std.testing.expectError(
        error.MissingField,
        parseAlloc(std.testing.allocator, raw),
    );
}

test "win32 session state parse rejects newer schema before unknown field errors" {
    const raw =
        \\{"schema_version":2,"windows":[],"future":{"layout_generation":1}}
    ;

    try std.testing.expectError(
        error.UnsupportedVersion,
        parseAlloc(std.testing.allocator, raw),
    );
}

test "win32 session state parse keeps current schema strict about unknown fields" {
    const raw =
        \\{"schema_version":1,"windows":[],"future":{"layout_generation":1}}
    ;

    try std.testing.expectError(
        error.UnknownField,
        parseAlloc(std.testing.allocator, raw),
    );
}

test "security regression win32 session state parse owns restored pane strings" {
    const allocator = std.testing.allocator;
    var raw = try allocator.dupe(u8,
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\src\\noctty","profile":"pwsh","title_override":"Build"}}]}}]}]}
    );
    const raw_start = @intFromPtr(raw.ptr);
    const raw_end = raw_start + raw.len;
    const raw_len = raw.len;

    var parsed = try parseAlloc(allocator, raw);
    defer parsed.deinit();
    const pane = parsed.value.windows[0].tabs[0].layout.nodes[0].pane;
    for ([_][]const u8{ pane.cwd.?, pane.profile.?, pane.title_override.? }) |value| {
        const value_start = @intFromPtr(value.ptr);
        try std.testing.expect(value_start < raw_start or value_start >= raw_end);
    }

    allocator.free(raw);
    raw = undefined;
    const scratch = try allocator.alloc(u8, raw_len);
    defer allocator.free(scratch);
    @memset(scratch, 0xA5);

    try std.testing.expectEqualStrings("C:\\src\\noctty", pane.cwd.?);
    try std.testing.expectEqualStrings("pwsh", pane.profile.?);
    try std.testing.expectEqualStrings("Build", pane.title_override.?);
}

test "security regression win32 session state rejects NUL cwd" {
    const nul_cwd =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\safe\\\u0000INJECTED=yes"}}]}}]}]}
    ;
    try std.testing.expectError(error.InvalidPaneText, parseAlloc(std.testing.allocator, nul_cwd));
}

test "security regression win32 session state rejects control titles" {
    const control_title =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"title_override":"Build\u001b\u0007"}}]}}]}]}
    ;
    try std.testing.expectError(error.InvalidPaneText, parseAlloc(std.testing.allocator, control_title));
}

test "security regression win32 session state rejects carriage return title" {
    const carriage_return_title =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"title_override":"Build\rsubmitted"}}]}}]}]}
    ;
    try std.testing.expectError(
        error.InvalidPaneText,
        parseAlloc(std.testing.allocator, carriage_return_title),
    );
}

test "win32 session state accepts ordinary Windows paths" {
    const ordinary_path =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\Users\\amant\\src\\noctty"}}]}}]}]}
    ;
    var parsed = try parseAlloc(std.testing.allocator, ordinary_path);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "C:\\Users\\amant\\src\\noctty",
        parsed.value.windows[0].tabs[0].layout.nodes[0].pane.cwd.?,
    );
}

fn fuzzParseSessionState(_: void, raw: []const u8) !void {
    // Bound the input the same way the persistence read allowance does; that
    // constant lives with the reader, not the schema.
    if (raw.len > @import("win32_session_persistence.zig").default_max_state_bytes) return;
    var parsed = parseAlloc(std.testing.allocator, raw) catch return;
    defer parsed.deinit();
}

test "fuzz win32 session state parser" {
    try std.testing.fuzz({}, fuzzParseSessionState, .{ .corpus = &.{
        "{}",
        \\{"schema_version":1,"windows":[]}
        ,
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\src\\noctty"}}]}}]}]}
        ,
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\safe\\\u0000BAD=1"}}]}}]}]}
        ,
    } });
}

test "bounded fuzz campaign win32 session state parser" {
    const bounded_fuzz = @import("../testing/bounded_fuzz.zig");
    try bounded_fuzz.run({}, fuzzParseSessionState, .{
        .random_seed = 0x638F_E231_1CB4_9C5A,
        .corpus = &.{
            "{}",
            \\{"schema_version":1,"windows":[]}
            ,
            \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\src\\noctty"}}]}}]}]}
            ,
        },
    });
}

test "win32 session state encode rejects invalid split child index" {
    const nodes = [_]Node{
        .{ .split = .{
            .axis = .vertical,
            .ratio = 0.5,
            .first = 1,
            .second = 9,
        } },
        .{ .pane = .{ .cwd = "C:\\src\\noctty" } },
    };
    const tabs = [_]Tab{
        .{
            .selected_leaf = 0,
            .layout = .{
                .root = 0,
                .nodes = &nodes,
            },
        },
    };
    const windows = [_]Window{
        .{
            .selected_tab = 0,
            .tabs = &tabs,
        },
    };
    const state: SessionState = .{
        .windows = &windows,
    };

    try std.testing.expectError(
        error.InvalidNodeIndex,
        encodeAlloc(std.testing.allocator, state),
    );
}

test "win32 session state validates deep split layout without recursion" {
    const split_count: usize = 4096;
    const total_nodes = split_count * 2 + 1;

    const nodes = try std.testing.allocator.alloc(Node, total_nodes);
    defer std.testing.allocator.free(nodes);

    for (0..split_count) |i| {
        const split: Split = if (i + 1 < split_count)
            .{
                .axis = .horizontal,
                .ratio = 0.5,
                .first = @intCast(i + 1),
                .second = @intCast(split_count + i),
            }
        else
            .{
                .axis = .horizontal,
                .ratio = 0.5,
                .first = @intCast(split_count + i),
                .second = @intCast(split_count + i + 1),
            };
        nodes[i] = .{ .split = split };
    }

    for (split_count..total_nodes) |i| {
        nodes[i] = .{ .pane = .{ .cwd = "C:\\src\\noctty" } };
    }

    const tabs = [_]Tab{
        .{
            .selected_leaf = split_count,
            .layout = .{
                .root = 0,
                .nodes = nodes,
            },
        },
    };
    const windows = [_]Window{
        .{
            .selected_tab = 0,
            .tabs = &tabs,
        },
    };

    try validateAlloc(std.testing.allocator, .{
        .windows = &windows,
    });
}

test "win32 session state rejects layout node count above handle range" {
    const nodes = try std.testing.allocator.alloc(Node, std.math.maxInt(u16) + 1);
    defer std.testing.allocator.free(nodes);
    @memset(nodes, .{ .pane = .{} });

    const tabs = [_]Tab{
        .{
            .selected_leaf = 0,
            .layout = .{
                .root = 0,
                .nodes = nodes,
            },
        },
    };
    const windows = [_]Window{
        .{
            .selected_tab = 0,
            .tabs = &tabs,
        },
    };

    try std.testing.expectError(error.TooManySessionLayoutNodes, validateAlloc(std.testing.allocator, .{
        .windows = &windows,
    }));
}

test "win32 session state parse rejects shared-node layout before DFS stack overflow" {
    const raw =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"split":{"axis":"horizontal","ratio":0.5,"first":1,"second":2}},{"split":{"axis":"vertical","ratio":0.5,"first":2,"second":3}},{"pane":{"cwd":"C:\\src\\noctty"}},{"pane":{"cwd":"C:\\logs"}}]}}]}]}
    ;

    try std.testing.expectError(
        error.InvalidTreeShape,
        parseAlloc(std.testing.allocator, raw),
    );
}

test "win32 session state parse rejects self-referential layout before DFS stack overflow" {
    const raw =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"split":{"axis":"horizontal","ratio":0.5,"first":0,"second":1}},{"pane":{"cwd":"C:\\src\\noctty"}}]}}]}]}
    ;

    try std.testing.expectError(
        error.InvalidTreeShape,
        parseAlloc(std.testing.allocator, raw),
    );
}
