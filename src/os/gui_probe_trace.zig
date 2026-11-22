//! An env-gated probe record for the hosted GUI probe (test/windows/gui-hosted-probe.ps1).
//!
//! When `NOCTTY_GUI_PROBE_TRACE` is "1", `ITaskbarList3::HrInit`'s HRESULT becomes an info line (scope
//! `gui_probe`). Without the variable nothing is written and nothing else changes. The probe needs it
//! because `TaskbarProgress.init` logs only its failure, as an error name, so "HrInit succeeded" could not
//! be read from the product before. The renderer half of the probe needs no record of its own: the
//! existing `initialized driver=WARP` line and the absence of every logged backend switch bind the backend.

const std = @import("std");

const log = std.log.scoped(.gui_probe);

pub const env_var = "NOCTTY_GUI_PROBE_TRACE";

/// The variable's value turns the record on only when it is exactly "1" (surrounding whitespace aside).
pub fn parseEnabled(raw: ?[]const u8) bool {
    const value = raw orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, value, &std.ascii.whitespace), "1");
}

/// The line for `HrInit`'s HRESULT `hr` when the record is on, otherwise null. `buf` holds the line.
pub fn hrInitLine(on: bool, hr: i32, buf: []u8) ?[]const u8 {
    if (!on) return null;
    return std.fmt.bufPrint(buf, "gui-probe hrinit hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))}) catch null;
}

/// The line for `hr` given the variable's raw value (null when unset).
pub fn hrInitLineFor(raw: ?[]const u8, hr: i32, buf: []u8) ?[]const u8 {
    return hrInitLine(parseEnabled(raw), hr, buf);
}

// 0 not read yet, 1 off, 2 on. Read once; a race only reads the same value twice.
var state = std.atomic.Value(u8).init(0);

/// Whether the process environment turns the record on.
pub fn enabled() bool {
    switch (state.load(.acquire)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    // A small fixed buffer, not page_allocator (renderer.md 2026-10-11, trap (1)); a longer value is off.
    var storage: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const raw: ?[]u8 = std.process.getEnvVarOwned(fba.allocator(), env_var) catch null;
    const on = parseEnabled(raw);
    state.store(if (on) 2 else 1, .release);
    return on;
}

/// Writes `HrInit`'s HRESULT as an info line when the environment turns the record on; otherwise does nothing.
pub fn noteHrInit(hr: i32) void {
    if (!enabled()) return;
    var buf: [64]u8 = undefined;
    if (hrInitLine(true, hr, &buf)) |text| log.info("{s}", .{text});
}

test "gui probe hrinit record appears only under the variable" {
    var buf: [64]u8 = undefined;
    for ([_]i32{ 0, @bitCast(@as(u32, 0x80004005)) }) |hr| {
        try std.testing.expect(hrInitLineFor(null, hr, &buf) == null);
        try std.testing.expect(hrInitLineFor("", hr, &buf) == null);
        try std.testing.expect(hrInitLineFor("0", hr, &buf) == null);
        try std.testing.expect(hrInitLineFor("true", hr, &buf) == null);
        try std.testing.expect(hrInitLineFor("11", hr, &buf) == null);
        try std.testing.expect(hrInitLineFor("1", hr, &buf) != null);
        try std.testing.expect(hrInitLineFor(" 1\r\n", hr, &buf) != null);
    }
}

test "gui probe hrinit line carries the HRESULT" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("gui-probe hrinit hr=0x00000000", hrInitLineFor("1", 0, &buf).?);
    // E_NOTIMPL, what a private desktop's taskbar returns here (F9).
    try std.testing.expectEqualStrings("gui-probe hrinit hr=0x80004001", hrInitLineFor("1", @bitCast(@as(u32, 0x80004001)), &buf).?);
    try std.testing.expectEqualStrings("gui-probe hrinit hr=0x80004005", hrInitLineFor("1", @bitCast(@as(u32, 0x80004005)), &buf).?);
}
