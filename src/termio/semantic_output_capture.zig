const std = @import("std");
const semantic_output = @import("../terminal/semantic_output.zig");

/// Fixed-memory capture of semantic terminal output produced by one PTY read
/// batch. This is owned and driven by StreamHandler while the terminal mutex is
/// held, then copied into the UI transport after that mutex is released.
pub const SemanticOutputCapture = struct {
    pub const capacity = semantic_output.capacity;

    pub const Batch = struct {
        bytes: [capacity]u8,
        len: usize,
        omitted_after: bool,
        reset_before: bool,

        pub fn slice(self: *const Batch) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    bytes: [capacity]u8 = undefined,
    len: usize = 0,
    active: bool = false,
    omitted_after: bool = false,
    reset_before: bool = false,

    pub fn begin(self: *SemanticOutputCapture, interested: bool) void {
        self.len = 0;
        self.active = interested;
        self.omitted_after = false;
        self.reset_before = false;
    }

    pub fn recordPrint(self: *SemanticOutputCapture, cp: u21) void {
        if (!self.active or self.omitted_after) return;

        var encoded: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(cp, &encoded) catch {
            self.omitRemainder();
            return;
        };
        self.record(encoded[0..encoded_len]);
    }

    pub fn recordCarriageReturn(self: *SemanticOutputCapture) void {
        self.record("\r");
    }

    pub fn recordLinefeed(self: *SemanticOutputCapture) void {
        self.record("\n");
    }

    pub fn recordTab(self: *SemanticOutputCapture) void {
        self.record("\t");
    }

    pub fn omitRemainder(self: *SemanticOutputCapture) void {
        if (self.active) self.omitted_after = true;
    }

    pub fn resetForFullReset(self: *SemanticOutputCapture) void {
        if (!self.active) return;
        self.len = 0;
        self.omitted_after = false;
        self.reset_before = true;
    }

    pub fn finish(self: *SemanticOutputCapture) Batch {
        var result: Batch = .{
            .bytes = undefined,
            .len = self.len,
            .omitted_after = self.omitted_after,
            .reset_before = self.reset_before,
        };
        @memcpy(result.bytes[0..self.len], self.bytes[0..self.len]);
        self.active = false;
        return result;
    }

    fn record(self: *SemanticOutputCapture, value: []const u8) void {
        if (!self.active or self.omitted_after or value.len == 0) return;
        if (value.len > self.bytes.len - self.len) {
            self.omitted_after = true;
            return;
        }
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
    }
};

test "semantic output capture uninterested fast path" {
    var capture: SemanticOutputCapture = .{};
    capture.begin(false);
    capture.recordPrint('A');
    for (0..3) |_| capture.recordPrint('B');
    capture.recordCarriageReturn();
    capture.recordLinefeed();
    capture.recordTab();
    const batch = capture.finish();
    try std.testing.expectEqual(@as(usize, 0), batch.len);
    try std.testing.expect(!batch.omitted_after);
}

test "semantic output capture preserves utf8 and control order" {
    var capture: SemanticOutputCapture = .{};
    capture.begin(true);
    capture.recordPrint('A');
    capture.recordPrint('🙂');
    capture.recordCarriageReturn();
    capture.recordLinefeed();
    capture.recordTab();
    for (0..2) |_| capture.recordPrint('é');
    const batch = capture.finish();
    try std.testing.expectEqualStrings("A🙂\r\n\téé", batch.slice());
    try std.testing.expect(!batch.omitted_after);
}

test "semantic output finished batch owns bytes across capture reuse" {
    var capture: SemanticOutputCapture = .{};
    capture.begin(true);
    capture.recordPrint('A');
    const first = capture.finish();
    try std.testing.expectEqualStrings("A", first.slice());

    capture.begin(true);
    capture.recordPrint('B');
    const batch = capture.finish();
    try std.testing.expectEqualStrings("B", batch.slice());
    try std.testing.expectEqualStrings("A", first.slice());
    try std.testing.expect(!batch.omitted_after);
}

test "semantic output full reset discards prior bytes and omission" {
    var capture: SemanticOutputCapture = .{};
    capture.begin(true);
    capture.recordPrint('A');
    capture.omitRemainder();
    capture.resetForFullReset();
    capture.recordPrint('B');
    const batch = capture.finish();
    try std.testing.expectEqualStrings("B", batch.slice());
    try std.testing.expect(!batch.omitted_after);
    try std.testing.expect(batch.reset_before);
}

test "semantic output capture retains codepoint-aligned prefix before omission" {
    var capture: SemanticOutputCapture = .{};
    capture.begin(true);
    for (0..SemanticOutputCapture.capacity - 1) |_| capture.recordPrint('x');
    capture.recordPrint('🙂');
    capture.recordPrint('z');
    const batch = capture.finish();
    try std.testing.expectEqual(
        SemanticOutputCapture.capacity - 1,
        batch.len,
    );
    try std.testing.expect(std.unicode.utf8ValidateSlice(batch.slice()));
    try std.testing.expect(batch.omitted_after);
}

test "semantic output capture explicit partial error omission retains prefix" {
    var capture: SemanticOutputCapture = .{};
    capture.begin(true);
    for (0..3) |_| capture.recordPrint('R');
    capture.omitRemainder();
    capture.recordPrint('X');
    const batch = capture.finish();
    try std.testing.expectEqualStrings("RRR", batch.slice());
    try std.testing.expect(batch.omitted_after);
}
