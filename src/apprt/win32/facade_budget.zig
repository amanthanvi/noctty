//! Test-only guard on the Win32 facade, `../win32.zig`. New code imports each
//! name from the module that owns it: no new `*_runtime` dependency bag, no
//! bag entry and no forwarding alias on the facade. The budget is exact both
//! ways, so the change that shrinks the facade pastes the numbers this test
//! prints and no later change can regrow into the slack; raising a row needs a
//! `// why:` on that row. The facts comptime cannot see (which files import
//! win32.zig, and that bags are declared only there) are pinned in
//! test/windows/flagship/contracts/Contracts.20-Zig.ps1.
const std = @import("std");
const win32 = @import("../win32.zig");

const budget = .{
    // Entries in each `pub const *_runtime` bag on the facade.
    .bags = .{
        .chrome_scene_runtime = 65,
        .chrome_scene_test_runtime = 4,
        .overlay_session_runtime = 45,
        .overlay_session_test_runtime = 5,
        .palette_controller_runtime = 44,
        .palette_controller_test_runtime = 7,
        .search_controls_runtime = 68,
        .search_controls_test_runtime = 4,
        .window_state_runtime = 26,
        .window_state_test_runtime = 22,
        .host_test_runtime = 2,
        .surface_presentation_runtime = 12,
        .surface_presentation_test_runtime = 3,
        .session_runtime = 48,
        .quick_terminal_host_runtime = 32,
        .test_support_runtime = 52,
    },
    // The facade's pub declarations: what the files that import it can reach.
    .facade_pub_decls = 545,
    // Root declarations of win32.zig whose value is a field access (`a.b`).
    .facade_aliases = 315,
    // Fields of win32.App named `test_*`.
    .app_test_hooks = 10,
};

/// Leaf modules under win32/, each `.{ .file, .module, .source, .pub_decls }`.
/// None of a leaf's own `@import`s may be a `facade_owners` path; what those
/// imports import in turn is not checked.
const leaves = .{
    .{
        .file = "child_window.zig",
        .module = @import("child_window.zig"),
        .source = @embedFile("child_window.zig"),
        .pub_decls = 16,
    },
};

/// The facade, the files that own its App, Host and Surface, and
/// `../../apprt.zig`, which re-exports the facade as `apprt.win32` (a leaf
/// that needs an `apprt` type imports the file that owns it, such as
/// `../action.zig`).
const facade_owners = [_][]const u8{
    "../win32.zig",
    "app.zig",
    "host.zig",
    "terminal_window.zig",
    "../../apprt.zig",
};

const import_the_owner = "import the name from the module that owns it; do not add a bag entry or a facade alias";

test "win32 facade budget: bags, aliases, pub surface and App test hooks do not grow" {
    @setEvalBranchQuota(100_000);
    const decls = @typeInfo(win32).@"struct".decls;
    inline for (decls) |decl| {
        if (comptime !std.mem.endsWith(u8, decl.name, "_runtime")) continue;
        if (!@hasField(@TypeOf(budget.bags), decl.name)) {
            std.debug.print("win32.{s} is a new dependency bag: {s}\n", .{ decl.name, import_the_owner });
            return error.NewDependencyBag;
        }
        try ratchet(
            "win32." ++ decl.name ++ " entries",
            @typeInfo(@TypeOf(@field(win32, decl.name))).@"struct".fields.len,
            @field(budget.bags, decl.name),
            error.FacadeBudgetExceeded,
            import_the_owner,
        );
    }
    inline for (@typeInfo(@TypeOf(budget.bags)).@"struct".fields) |row| {
        if (!@hasDecl(win32, row.name)) {
            std.debug.print("win32.{s} is gone: delete its row from the budget\n", .{row.name});
            return error.FacadeBudgetStale;
        }
    }
    try rejectPrivateBags(std.testing.allocator, @embedFile("../win32.zig"));
    try ratchet("win32.zig pub declarations", decls.len, budget.facade_pub_decls, error.FacadeBudgetExceeded, import_the_owner);
    try ratchet(
        "win32.zig forwarding aliases",
        try aliasCount(std.testing.allocator, @embedFile("../win32.zig")),
        budget.facade_aliases,
        error.FacadeBudgetExceeded,
        import_the_owner,
    );
    try ratchet(
        "win32.App test_* fields",
        comptime testHookCount(win32.App),
        budget.app_test_hooks,
        error.FacadeBudgetExceeded,
        "give the module under test its own seam instead of an App test hook",
    );
}

test "win32 leaf modules import no facade owner and keep their pub surface" {
    inline for (leaves) |leaf| {
        var imports = std.mem.splitSequence(u8, leaf.source, "@import(\"");
        _ = imports.first();
        while (imports.next()) |chunk| {
            const path = chunk[0..std.mem.indexOfScalar(u8, chunk, '"').?];
            if (try isFacadeOwner(std.testing.allocator, path)) {
                std.debug.print("{s} imports {s}: a leaf takes nothing from the facade or its owners\n", .{ leaf.file, path });
                return error.LeafImportsFacade;
            }
        }
        try ratchet(
            leaf.file ++ " pub declarations",
            @typeInfo(leaf.module).@"struct".decls.len,
            leaf.pub_decls,
            error.LeafSurfaceGrew,
            "keep the new declaration private to the leaf",
        );
    }
}

/// Compares resolved paths, so `./host.zig`, `../win32/host.zig` or a
/// backslash spelling of an owner is still that owner.
fn isFacadeOwner(gpa: std.mem.Allocator, path: []const u8) !bool {
    const resolved = try resolveFromLeafDir(gpa, path);
    defer gpa.free(resolved);
    for (facade_owners) |owner| {
        const want = try resolveFromLeafDir(gpa, owner);
        defer gpa.free(want);
        if (std.mem.eql(u8, resolved, want)) return true;
    }
    return false;
}

fn resolveFromLeafDir(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const slashed = try gpa.dupe(u8, path);
    defer gpa.free(slashed);
    std.mem.replaceScalar(u8, slashed, '\\', '/');
    return std.fs.path.resolvePosix(gpa, &.{ "src/apprt/win32", slashed });
}

test "win32 leaf import check sees an owner through any spelling of its path" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "host.zig", "./host.zig", "../win32/host.zig", ".\\app.zig", "../win32.zig", "./../win32.zig", "../../apprt.zig", "../../../src/apprt.zig" }) |owner| {
        try std.testing.expect(try isFacadeOwner(gpa, owner));
    }
    for ([_][]const u8{ "chrome_layout.zig", "../action.zig", "../win32_uia/events.zig", "../../apprt/win32/text.zig" }) |other| {
        try std.testing.expect(!try isFacadeOwner(gpa, other));
    }
}

fn ratchet(what: []const u8, measured: usize, row: usize, over: anyerror, fix: []const u8) anyerror!void {
    if (measured > row) {
        std.debug.print("{s}: {d}, budget {d}: {s}\n", .{ what, measured, row, fix });
        return over;
    }
    if (measured < row) {
        std.debug.print("{s}: {d}, budget {d}: paste {d} into src/apprt/win32/facade_budget.zig\n", .{ what, measured, row, measured });
        return error.FacadeBudgetStale;
    }
}

fn aliasCount(gpa: std.mem.Allocator, source: [:0]const u8) !usize {
    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    var count: usize = 0;
    for (tree.rootDecls()) |node| {
        const decl = tree.fullVarDecl(node) orelse continue;
        const value = decl.ast.init_node.unwrap() orelse continue;
        if (tree.nodeTag(value) == .field_access) count += 1;
    }
    return count;
}

/// `@typeInfo` lists only pub declarations, so a private bag (one a
/// generic such as Fixtures takes as an argument) is found in the source.
fn rejectPrivateBags(gpa: std.mem.Allocator, source: [:0]const u8) !void {
    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    for (tree.rootDecls()) |node| {
        const decl = tree.fullVarDecl(node) orelse continue;
        if (decl.visib_token != null) continue;
        const name = tree.tokenSlice(decl.ast.mut_token + 1);
        if (!std.mem.endsWith(u8, name, "_runtime")) continue;
        std.debug.print("win32.{s} is a new dependency bag: {s}\n", .{ name, import_the_owner });
        return error.NewDependencyBag;
    }
}

fn testHookCount(comptime T: type) usize {
    var count: usize = 0;
    for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.startsWith(u8, field.name, "test_")) count += 1;
    }
    return count;
}
