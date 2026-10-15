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
        /// The consumer forgets what it was holding from before (typed input
        /// waiting to be seen echoed) ahead of the byte at this index: 0 for
        /// a full reset, which also dropped everything captured before it.
        reset_at: ?usize,

        pub fn slice(self: *const Batch) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    bytes: [capacity]u8 = undefined,
    len: usize = 0,
    active: bool = false,
    omitted_after: bool = false,
    reset_at: ?usize = null,

    pub fn begin(self: *SemanticOutputCapture, interested: bool) void {
        self.len = 0;
        self.active = interested;
        self.omitted_after = false;
        self.reset_at = null;
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
        self.reset_at = 0;
    }

    /// The program switched between the main and the alternate screen. What
    /// the consumer still holds from before (typed input waiting to be seen
    /// echoed) can no longer be told apart from output of the other screen,
    /// so it is dropped at this point of the stream: what was captured so
    /// far stays ahead of the reset, and only the first switch of a batch
    /// matters, as nothing is held again until the batch is delivered.
    pub fn noteScreenSwitch(self: *SemanticOutputCapture) void {
        if (self.active and self.reset_at == null) self.reset_at = self.len;
    }

    pub fn finish(self: *SemanticOutputCapture) Batch {
        var result: Batch = .{
            .bytes = undefined,
            .len = self.len,
            .omitted_after = self.omitted_after,
            .reset_at = self.reset_at,
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
    try std.testing.expectEqual(@as(?usize, 0), batch.reset_at);
}

test "semantic output screen switch resets continuity where it happened" {
    var capture: SemanticOutputCapture = .{};
    capture.begin(true);
    capture.recordPrint('A');
    capture.noteScreenSwitch();
    capture.recordPrint('B');
    // Only the first switch counts: the consumer holds nothing new until the
    // batch is delivered.
    capture.noteScreenSwitch();
    const batch = capture.finish();
    try std.testing.expectEqualStrings("AB", batch.slice());
    try std.testing.expectEqual(@as(?usize, 1), batch.reset_at);
    try std.testing.expect(!batch.omitted_after);

    // A full reset discards what came before, so it resets at the start
    // whether or not a switch came first, and a switch after it adds nothing.
    capture.begin(true);
    capture.recordPrint('A');
    capture.noteScreenSwitch();
    capture.resetForFullReset();
    capture.recordPrint('B');
    capture.noteScreenSwitch();
    const reset = capture.finish();
    try std.testing.expectEqualStrings("B", reset.slice());
    try std.testing.expectEqual(@as(?usize, 0), reset.reset_at);

    // The reset belongs to one batch, and an uninterested one records nothing.
    capture.begin(true);
    try std.testing.expectEqual(@as(?usize, null), capture.finish().reset_at);
    capture.begin(false);
    capture.noteScreenSwitch();
    try std.testing.expectEqual(@as(?usize, null), capture.finish().reset_at);
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
