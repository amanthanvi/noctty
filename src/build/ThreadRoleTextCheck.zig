//! A build step that fails when an exe built without the runtime thread-role
//! layer holds its text (`text`, which starts every panic of the layer):
//! PLAN.md §2.7 acceptance test 14, a ReleaseFast app exe holds none of the
//! layer's panic strings. build.zig adds it to the install step of an app
//! exe whose mode builds without the layer (`Config.threadRoles`). Fork-owned,
//! so the check stays out of upstream's build.zig and Config.zig.
const ThreadRoleTextCheck = @This();

const std = @import("std");

/// The text every panic of the runtime thread-role layer starts with
/// (`src/sync`).
pub const text = "thread-role layer:";

step: std.Build.Step,
exe: std.Build.LazyPath,

pub fn create(b: *std.Build, exe: std.Build.LazyPath) *ThreadRoleTextCheck {
    const check = b.allocator.create(ThreadRoleTextCheck) catch @panic("OOM");
    check.* = .{
        .step = .init(.{
            .id = .custom,
            .name = "check the exe holds no thread-role layer text",
            .owner = b,
            .makeFn = make,
        }),
        .exe = exe.dupe(b),
    };
    exe.addStepDependencies(&check.step);
    return check;
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const check: *ThreadRoleTextCheck = @fieldParentPtr("step", step);
    const path = check.exe.getPath2(step.owner, step);
    const file = std.fs.cwd().openFile(path, .{}) catch |err|
        return step.fail("unable to open '{s}': {s}", .{ path, @errorName(err) });
    defer file.close();
    var buf: [64 * 1024]u8 = undefined;
    const holds = fileHolds(file, text, &buf) catch |err|
        return step.fail("unable to read '{s}': {s}", .{ path, @errorName(err) });
    if (holds) return step.fail(
        "'{s}' holds the runtime thread-role layer's text \"{s}\", " ++
            "but its mode builds without the layer (PLAN.md 2.7, acceptance test 14)",
        .{ path, text },
    );
}

/// Whether `file`, read from its position to its end, holds `needle`,
/// wherever the reads into `buf` split it. `buf` must be longer than
/// `needle`.
pub fn fileHolds(file: std.fs.File, needle: []const u8, buf: []u8) !bool {
    std.debug.assert(needle.len > 0 and buf.len > needle.len);
    // The bytes carried over from the last read: a match that the next read
    // completes starts in its last `needle.len - 1` bytes.
    var kept: usize = 0;
    while (true) {
        const n = try file.read(buf[kept..]);
        if (n == 0) return false;
        const end = kept + n;
        if (std.mem.indexOf(u8, buf[0..end], needle) != null) return true;
        kept = @min(end, needle.len - 1);
        std.mem.copyForwards(u8, buf[0..kept], buf[end - kept .. end]);
    }
}

test "fileHolds finds the text at every split of the reads, and only it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [text.len + 7]u8 = undefined;
    var bytes: [3 * buf.len]u8 = undefined;

    // At each offset, so a read boundary falls before, inside and after it.
    for (0..bytes.len - text.len + 1) |at| {
        @memset(&bytes, '.');
        @memcpy(bytes[at..][0..text.len], text);
        try tmp.dir.writeFile(.{ .sub_path = "exe", .data = &bytes });
        const file = try tmp.dir.openFile("exe", .{});
        defer file.close();
        try std.testing.expect(try fileHolds(file, text, &buf));
    }

    // The text less its last byte, across a boundary, and then nothing.
    @memset(&bytes, '.');
    @memcpy(bytes[buf.len - 3 ..][0 .. text.len - 1], text[0 .. text.len - 1]);
    try tmp.dir.writeFile(.{ .sub_path = "exe", .data = &bytes });
    const file = try tmp.dir.openFile("exe", .{});
    defer file.close();
    try std.testing.expect(!try fileHolds(file, text, &buf));
}
