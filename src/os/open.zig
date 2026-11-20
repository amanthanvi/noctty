const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");

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
    alloc: Allocator,
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    // If an embedder declines an untrusted URL, refuse it rather than skip
    // the apprt's safety checks by passing it to FileProtocolHandler, which
    // runs whatever program the target names.
    if (!genericOpenAllowed(kind)) return error.UntrustedLink;
    if (builtin.os.tag != .windows) return error.Unimplemented;

    var exe: std.process.Child = .init(
        &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        alloc,
    );

    // Ignore anything from stdout. This must be set before spawning the
    // process.
    exe.stdout_behavior = .Ignore;
    // Pipe stderr so we can log the stderr from the command. This must be set
    // before spawning the process.
    exe.stderr_behavior = .Pipe;

    // Spawn the process on our same thread so we can detect failure
    // quickly.
    try exe.spawn();

    // Create a thread that handles collecting output and reaping the process.
    // This is done in a separate thread because SOME open implementations block
    // and some do not. It's easier to just spawn a thread to handle this so
    // that we never block.
    const thread = try std.Thread.spawn(.{}, openThread, .{exe});
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

fn openThread(exe_: std.process.Child) void {
    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    if (exe.stderr) |stderr| {
        var buffer: [256]u8 = undefined;
        var stream = stderr.readerStreaming(&buffer);
        const reader = &stream.interface;
        while (true) {
            const line = reader.takeDelimiterExclusive('\n') catch |outer| switch (outer) {
                error.EndOfStream => break,
                error.ReadFailed => break,
                error.StreamTooLong => reader.take(buffer.len) catch |inner| switch (inner) {
                    error.ReadFailed => break,
                    error.EndOfStream => break,
                },
            };
            log.warn("open stderr={s}", .{line});
        }
    }
    _ = exe.wait() catch {};
}
