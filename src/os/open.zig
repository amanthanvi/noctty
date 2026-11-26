const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
const redact = @import("redact.zig");
const thread_role = @import("../sync/thread_role.zig");

const log = std.log.scoped(.@"os-open");

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
///
/// This function is purposely simple for the sake of providing
/// some portable way to open URLs. If you are implementing an
/// apprt for Ghostty, you should consider doing something special-cased
/// for your platform.
///
/// Untrusted kinds (`unknown`, `osc8`) return `error.UntrustedLink`
/// because the apprt must check them first.
pub fn open(
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    // If an embedder declines an untrusted URL, refuse it rather than skip
    // the apprt's safety checks by passing it to FileProtocolHandler, which
    // runs whatever program the target names.
    if (!genericOpenAllowed(kind)) return error.UntrustedLink;
    if (builtin.target.os.tag != .windows) return error.Unimplemented;

    var spawn_opts: std.process.SpawnOptions = .{
        .argv = &.{ "rundll32", "url.dll,FileProtocolHandler", url },
    };

    // Ignore anything from stdout. This must be set before spawning the
    // process.
    spawn_opts.stdout = .ignore;
    // Pipe stderr so we can log the stderr from the command. This must be set
    // before spawning the process.
    spawn_opts.stderr = .pipe;

    // Spawn the process on our same thread so we can detect failure
    // quickly.
    const exe = try std.process.spawn(global.io(), spawn_opts);

    // Create a thread that handles collecting output and reaping the process.
    // This is done in a separate thread because SOME open implementations block
    // and some do not. It's easier to just spawn a thread to handle this so
    // that we never block.
    const thread = try std.Thread.spawn(.{}, openThread, .{ global.io(), exe });
    thread.detach();
}

/// Whether `open` may pass a link of this kind to the generic opener. Kept
/// apart from `open` so a test checks the decision without starting a
/// process.
fn genericOpenAllowed(kind: apprt.action.OpenUrl.Kind) bool {
    return switch (kind) {
        .unknown, .osc8 => false,
        .text, .html => true,
    };
}

test "untrusted links have no generic opener fallback" {
    // Not through `open`: if its refusal ever moved below the spawn, the test
    // would start rundll32 with the target on the desktop running the suite.
    try std.testing.expect(!genericOpenAllowed(.unknown));
    try std.testing.expect(!genericOpenAllowed(.osc8));
    try std.testing.expect(genericOpenAllowed(.text));
    try std.testing.expect(genericOpenAllowed(.html));
}

fn openThread(io: std.Io, exe_: std.process.Child) void {
    const role_scope = thread_role.enter(.{ .worker = "open" });
    defer role_scope.exit();
    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    if (exe.stderr) |stderr| {
        var buffer: [256]u8 = undefined;
        var stream = stderr.readerStreaming(io, &buffer);
        _ = drainOpenerStderr(&stream.interface);
    }
    _ = exe.wait(io) catch {};
}

/// Reads an opener's stderr to its end, logging each line, and returns how
/// many lines it read. Lines are read inclusively so the delimiter is
/// consumed (upstream 3b8141fbd, after the stepping stone):
/// `takeDelimiterExclusive` leaves the '\n' buffered, so once the child
/// wrote a line every later call returned an empty slice and the loop spun
/// forever. A line is logged by its size only: an opener's stderr can echo
/// the link it was given (AGENTS.md "Logging").
fn drainOpenerStderr(reader: *std.Io.Reader) usize {
    var lines: usize = 0;
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |outer| switch (outer) {
            error.EndOfStream => break,
            error.ReadFailed => break,
            error.StreamTooLong => reader.take(reader.buffer.len) catch |inner| switch (inner) {
                error.ReadFailed => break,
                error.EndOfStream => break,
            },
        };
        lines += 1;
        log.warn("open stderr={f}", .{redact.bytes(std.mem.trimEnd(u8, line, "\n"))});
    }
    return lines;
}

test "drainOpenerStderr consumes each line's delimiter and ends" {
    var reader: std.Io.Reader = .fixed("first line\nsecond line\n");
    try std.testing.expectEqual(@as(usize, 2), drainOpenerStderr(&reader));
}
