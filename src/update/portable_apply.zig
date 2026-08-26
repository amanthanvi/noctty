//! Portable ZIP updater apply / rollback (C29).
//!
//! Stages the new tree beside the current portable root, swaps, and
//! keeps `.apply-old` for one rollback. Never requests elevation.

const std = @import("std");

pub const apply_new_suffix = ".apply-new";
pub const apply_old_suffix = ".apply-old";

pub fn siblingPath(alloc: std.mem.Allocator, root: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ root, suffix });
}

pub fn isPortableZipName(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, "-portable.zip") or
        std.ascii.endsWithIgnoreCase(name, ".zip");
}

/// Plan the swap. Callers extract `zip_path` into `new_path`, then
/// rename `root` → `old_path` and `new_path` → `root`.
pub const SwapPlan = struct {
    root: []const u8,
    new_path: []const u8,
    old_path: []const u8,

    pub fn deinit(self: *SwapPlan, alloc: std.mem.Allocator) void {
        alloc.free(self.new_path);
        alloc.free(self.old_path);
        self.* = undefined;
    }
};

pub fn planSwap(alloc: std.mem.Allocator, root: []const u8) !SwapPlan {
    return .{
        .root = root,
        .new_path = try siblingPath(alloc, root, apply_new_suffix),
        .old_path = try siblingPath(alloc, root, apply_old_suffix),
    };
}

pub fn rollback(root: []const u8, old_path: []const u8) !void {
    std.fs.deleteTreeAbsolute(root) catch {};
    try std.fs.renameAbsolute(old_path, root);
}

/// Rename `root` → `old_path` and `new_path` → `root`. Caller extracted
/// the staged tree into `new_path` first. Rolls back if the second
/// rename fails.
pub fn applySwap(plan: SwapPlan) !void {
    std.fs.deleteTreeAbsolute(plan.old_path) catch {};
    try std.fs.renameAbsolute(plan.root, plan.old_path);
    errdefer std.fs.renameAbsolute(plan.old_path, plan.root) catch {};
    try std.fs.renameAbsolute(plan.new_path, plan.root);
}

test "planSwap uses sibling suffixes" {
    const testing = std.testing;
    var plan = try planSwap(testing.allocator, "C:\\apps\\winghostty");
    defer plan.deinit(testing.allocator);
    try testing.expectEqualStrings("C:\\apps\\winghostty.apply-new", plan.new_path);
    try testing.expectEqualStrings("C:\\apps\\winghostty.apply-old", plan.old_path);
    try testing.expect(isPortableZipName("winghostty-1.3.120-windows-x64-portable.zip"));
}

test "applySwap renames then rollback restores" {
    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("root");
    try tmp.dir.writeFile(.{ .sub_path = "root/old.txt", .data = "old" });
    try tmp.dir.makePath("root.apply-new");
    try tmp.dir.writeFile(.{ .sub_path = "root.apply-new/new.txt", .data = "new" });

    const root = try tmp.dir.realpathAlloc(testing.allocator, "root");
    defer testing.allocator.free(root);
    var plan = try planSwap(testing.allocator, root);
    defer plan.deinit(testing.allocator);

    try applySwap(plan);
    try tmp.dir.access("root/new.txt", .{});
    try tmp.dir.access("root.apply-old/old.txt", .{});

    try rollback(root, plan.old_path);
    try tmp.dir.access("root/old.txt", .{});
}
