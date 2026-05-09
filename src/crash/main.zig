//! The crash package contains all the logic around crash handling,
//! whether that's setting up the system to catch crashes (Sentry client),
//! introspecting crash reports, writing crash reports to disk, etc.

const dir = @import("dir.zig");
const sentry_envelope = @import("sentry_envelope.zig");
const builtin = @import("builtin");

pub const sentry = @import("sentry.zig");
const minidump_windows = if (builtin.os.tag == .windows) @import("minidump_windows.zig") else struct {
    pub fn init(_: anytype) !void {}
    pub fn deinit() void {}
};
pub const Envelope = sentry_envelope.Envelope;
pub const defaultDir = dir.defaultDir;
pub const legacyGhosttyDir = dir.legacyGhosttyDir;
pub const Dir = dir.Dir;
pub const ReportIterator = dir.ReportIterator;
pub const Report = dir.Report;

// The main init/deinit functions for global state.
pub fn init(alloc: anytype) !void {
    try minidump_windows.init(alloc);
    try sentry.init(alloc);
}

pub fn deinit() void {
    sentry.deinit();
    minidump_windows.deinit();
}

test {
    @import("std").testing.refAllDecls(@This());
}
