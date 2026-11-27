//! The crash package contains all the logic around crash handling,
//! whether that's setting up the system to catch crashes (Sentry client),
//! introspecting crash reports, writing crash reports to disk, etc.

const std = @import("std");
const dir = @import("dir.zig");
const sentry_envelope = @import("sentry_envelope.zig");
const builtin = @import("builtin");
const global = @import("../global.zig");

pub const sentry = @import("sentry.zig");
const minidump_windows = if (builtin.os.tag == .windows) @import("minidump_windows.zig") else struct {
    pub fn init(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !void {}
    pub fn deinit() void {}
};
pub const Envelope = sentry_envelope.Envelope;
pub const defaultDir = dir.defaultDir;
pub const legacyGhosttyDir = dir.legacyGhosttyDir;
pub const Dir = dir.Dir;
pub const ReportIterator = dir.ReportIterator;
pub const Report = dir.Report;

// The main init/deinit functions for global state. Called from
// `global.init` once its environment and Io are set.
pub fn init(alloc: std.mem.Allocator) !void {
    {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        try minidump_windows.init(global.io(), alloc, &environ_map);
    }
    errdefer minidump_windows.deinit();
    // Sentry's init owns the map it is given (its init thread frees it).
    try sentry.init(alloc, try global.environMap());
}

pub fn deinit() void {
    sentry.deinit();
    minidump_windows.deinit();
}

test {
    @import("std").testing.refAllDecls(@This());
}
