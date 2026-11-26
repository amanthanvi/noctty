//! PLAN.md §2.7 acceptance test 14's two checks, fork-owned so they stay out
//! of upstream's build.zig and Config.zig:
//! - A build step that fails when an exe built without the runtime
//!   thread-role layer holds its text (`text`, which starts every panic of
//!   the layer): a ReleaseFast app exe holds none of the layer's panic
//!   strings. build.zig adds it to the install step of an app exe whose mode
//!   builds without the layer (`Config.threadRoles`). Zig 0.17's build graph
//!   has no custom steps, so the check is this file's `main`, built for the
//!   host and run on the exe.
//! - A test that src/sync imports no src/renderer file (`rendererImport`), so
//!   lib-vt's search code reaches the mutex wrapper without the renderer.
const std = @import("std");

/// The text every panic of the runtime thread-role layer starts with
/// (`src/sync`).
pub const text = "thread-role layer:";

/// The step that fails when `exe` holds `text`.
pub fn create(b: *std.Build, exe: std.Build.LazyPath) *std.Build.Step.Run {
    const tool = b.addExecutable(.{
        .name = "thread-role-text-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/ThreadRoleTextCheck.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.setName("check the exe holds no thread-role layer text");
    run.addFileArg(exe);
    run.expectExitCode(0);
    return run;
}

/// The host tool: `thread-role-text-check <exe>` exits 1, naming the text,
/// when the exe holds it.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.log.err("usage: thread-role-text-check <exe>", .{});
        std.process.exit(2);
    }
    const path = args[1];
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.log.err("unable to open '{s}': {t}", .{ path, err });
        std.process.exit(1);
    };
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    const holds = fileHolds(io, file, text, &buf) catch |err| {
        std.log.err("unable to read '{s}': {t}", .{ path, err });
        std.process.exit(1);
    };
    if (holds) {
        std.log.err(
            "'{s}' holds the runtime thread-role layer's text \"{s}\", " ++
                "but its mode builds without the layer (PLAN.md 2.7, acceptance test 14)",
            .{ path, text },
        );
        std.process.exit(1);
    }
}

/// Whether `file`, read from its position to its end, holds `needle`,
/// wherever the reads into `buf` split it. `buf` must be longer than
/// `needle`.
pub fn fileHolds(io: std.Io, file: std.Io.File, needle: []const u8, buf: []u8) !bool {
    std.debug.assert(needle.len > 0 and buf.len > needle.len);
    // The bytes carried over from the last read: a match that the next read
    // completes starts in its last `needle.len - 1` bytes.
    var kept: usize = 0;
    while (true) {
        const n = file.readStreaming(io, &.{buf[kept..]}) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => |e| return e,
        };
        if (n == 0) return false;
        const end = kept + n;
        if (std.mem.indexOf(u8, buf[0..end], needle) != null) return true;
        kept = @min(end, needle.len - 1);
        std.mem.copyForwards(u8, buf[0..kept], buf[end - kept .. end]);
    }
}

/// The first `@import` in `source`, a file in `dir` (a `/`-separated path
/// from the build root), of `src/renderer.zig` or a file under
/// `src/renderer/`, resolved as a relative import resolves and compared
/// without case, as NTFS opens it; null when there is none. It reads tokens,
/// so a comment or a string that only mentions an import does not count.
/// The caller frees the path.
fn rendererImport(gpa: std.mem.Allocator, dir: []const u8, source: [:0]const u8) !?[]u8 {
    var tokens: std.zig.Tokenizer = .init(source);
    while (true) {
        const token = tokens.next();
        switch (token.tag) {
            .eof => return null,
            .builtin => {},
            else => continue,
        }
        if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import")) continue;
        if (tokens.next().tag != .l_paren) continue;
        const literal = tokens.next();
        if (literal.tag != .string_literal) continue;
        const name = try std.zig.string_literal.parseAlloc(gpa, source[literal.loc.start..literal.loc.end]);
        defer gpa.free(name);
        // A name without `.zig` is a module (`std`, `build_options`).
        if (!std.ascii.endsWithIgnoreCase(name, ".zig")) continue;
        std.mem.replaceScalar(u8, name, '\\', '/');
        const path = try std.Io.Dir.path.resolveAllocPosix(gpa, &.{ dir, name });
        if (std.ascii.eqlIgnoreCase(path, "src/renderer.zig") or
            std.ascii.startsWithIgnoreCase(path, "src/renderer/")) return path;
        gpa.free(path);
    }
}

test "fileHolds finds the text at every split of the reads, and only it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [text.len + 7]u8 = undefined;
    var bytes: [3 * buf.len]u8 = undefined;

    // At each offset, so a read boundary falls before, inside and after it.
    for (0..bytes.len - text.len + 1) |at| {
        @memset(&bytes, '.');
        @memcpy(bytes[at..][0..text.len], text);
        try tmp.dir.writeFile(io, .{ .sub_path = "exe", .data = &bytes });
        const file = try tmp.dir.openFile(io, "exe", .{});
        defer file.close(io);
        try std.testing.expect(try fileHolds(io, file, text, &buf));
    }

    // The text less its last byte, across a boundary, and then nothing.
    @memset(&bytes, '.');
    @memcpy(bytes[buf.len - 3 ..][0 .. text.len - 1], text[0 .. text.len - 1]);
    try tmp.dir.writeFile(io, .{ .sub_path = "exe", .data = &bytes });
    const file = try tmp.dir.openFile(io, "exe", .{});
    defer file.close(io);
    try std.testing.expect(!try fileHolds(io, file, text, &buf));
}

test "src/sync imports no src/renderer file (acceptance test 14)" {
    // Read from the checkout the suite runs in (its build root), so a file
    // added to src/sync is read too.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sync = try std.Io.Dir.cwd().openDir(io, "src/sync", .{ .iterate = true });
    defer sync.close(io);
    var walker = try sync.walk(gpa);
    defer walker.deinit();
    var read_state_mutex = false;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try entry.dir.readFileAllocOptions(io, entry.basename, gpa, .limited(16 * 1024 * 1024), .of(u8), 0);
        defer gpa.free(source);
        var dir: std.ArrayList(u8) = .empty;
        defer dir.deinit(gpa);
        try dir.appendSlice(gpa, "src/sync");
        if (std.Io.Dir.path.dirname(entry.path)) |sub| {
            try dir.append(gpa, '/');
            try dir.appendSlice(gpa, sub);
            std.mem.replaceScalar(u8, dir.items, '\\', '/');
        }
        if (try rendererImport(gpa, dir.items, source)) |path| {
            defer gpa.free(path);
            std.debug.print("src/sync/{s} imports {s}\n", .{ entry.path, path });
            return error.SyncImportsRenderer;
        }
        if (std.mem.eql(u8, entry.path, "state_mutex.zig")) read_state_mutex = true;
    }
    // The walk read the layer's own tree.
    try std.testing.expect(read_state_mutex);
}

test "rendererImport reads an import by token, resolved as the compiler resolves it" {
    const gpa = std.testing.allocator;
    const Case = struct { dir: []const u8, source: [:0]const u8, path: ?[]const u8 };
    const cases = [_]Case{
        .{ .dir = "src/sync", .source = "const r = @import(\"../renderer.zig\");", .path = "src/renderer.zig" },
        .{ .dir = "src/sync", .source = "const s = @import(\"../renderer/State.zig\");", .path = "src/renderer/State.zig" },
        .{ .dir = "src/sync", .source = "_ = @import( \"./../Renderer/size.zig\" );", .path = "src/Renderer/size.zig" },
        .{ .dir = "src/sync/deep", .source = "const t = @import(\"../../renderer/Thread.zig\");", .path = "src/renderer/Thread.zig" },
        .{ .dir = "src/sync", .source = "const t = @import(\"thread_role.zig\");\nconst r = @import(\"../renderer.zig\");", .path = "src/renderer.zig" },
        // Modules, files elsewhere, and imports that are only mentioned.
        .{ .dir = "src/sync", .source = "const std = @import(\"std\");\nconst o = @import(\"build_options\");", .path = null },
        .{ .dir = "src/sync", .source = "const t = @import(\"thread_role.zig\");", .path = null },
        .{ .dir = "src/sync", .source = "const r = @import(\"renderer/State.zig\");", .path = null },
        .{ .dir = "src/sync", .source = "const r = @import(\"../renderer_size.zig\");", .path = null },
        .{ .dir = "src/sync", .source = "const r = @import(\"../os/renderer.zig\");", .path = null },
        .{ .dir = "src/sync", .source = "// const r = @import(\"../renderer.zig\");", .path = null },
        .{ .dir = "src/sync", .source = "const s = \"@import(\\\"../renderer.zig\\\")\";", .path = null },
    };
    for (cases) |case| {
        const found = try rendererImport(gpa, case.dir, case.source);
        defer if (found) |path| gpa.free(path);
        if (case.path) |expected| {
            try std.testing.expectEqualStrings(expected, found orelse return error.TestExpectedImport);
        } else {
            try std.testing.expect(found == null);
        }
    }
}
