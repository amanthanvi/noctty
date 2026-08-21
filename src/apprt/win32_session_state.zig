//! Windows session-state schema for a future restore flow.
//!
//! First slice only: layout, working-directory, profile, and explicit title
//! overrides. Deliberately excludes terminal contents, scrollback, command
//! lines, and other runtime process state.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const current_schema_version: u32 = 1;

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
    UnreachableNode,
    TooManySessionLayoutNodes,
};

pub const ValidateError = ValidationError || Allocator.Error;

const VersionHeader = struct {
    schema_version: u32,
};

const VisitFrame = struct {
    index: usize,
    expanded: bool,
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
    try validateAlloc(alloc, state);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try std.json.Stringify.value(state, .{
        .whitespace = .minified,
        .emit_null_optional_fields = false,
    }, &out.writer);

    return try out.toOwnedSlice();
}

pub fn parseAlloc(alloc: Allocator, raw: []const u8) !std.json.Parsed(SessionState) {
    var header = try std.json.parseFromSlice(VersionHeader, alloc, raw, .{
        .ignore_unknown_fields = true,
    });
    defer header.deinit();

    if (header.value.schema_version != current_schema_version) {
        return error.UnsupportedVersion;
    }

    var parsed = try std.json.parseFromSlice(SessionState, alloc, raw, .{
        .ignore_unknown_fields = false,
    });
    errdefer parsed.deinit();

    try validateAlloc(alloc, parsed.value);
    return parsed;
}

pub fn validateAlloc(alloc: Allocator, state: SessionState) ValidateError!void {
    if (state.schema_version != current_schema_version) {
        return error.UnsupportedVersion;
    }

    for (state.windows) |window| {
        try validateWindowRect(window);
        if (window.tabs.len == 0) return error.EmptyTabs;
        if (window.selected_tab >= window.tabs.len) return error.InvalidSelectedTab;

        for (window.tabs) |tab| {
            const leaf_count = try validateLayoutTree(alloc, tab.layout);
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

fn validateLayoutTree(alloc: Allocator, layout: LayoutTree) ValidateError!usize {
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
            .pane => {
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
