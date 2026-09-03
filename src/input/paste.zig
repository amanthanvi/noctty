const std = @import("std");
const Terminal = @import("../terminal/Terminal.zig");

// These are the set of byte values that are always replaced by
// a space (per xterm's behavior) for any text insertion method e.g.
// a paste, drag and drop, etc. These are copied directly from xterm's
// source.
const xterm_strip_bytes: []const u8 = &.{
    0x00, // NUL
    0x08, // BS
    0x05, // ENQ
    0x04, // EOT
    0x1B, // ESC
    0x7F, // DEL

    // These can be overridden by the running terminal program
    // via tcsetattr, so they aren't totally safe to hardcode like
    // this. In practice, I haven't seen modern programs change these
    // and its a much bigger architectural change to pass these through
    // so for now they're hardcoded.
    0x03, // VINTR (Ctrl+C)
    0x1C, // VQUIT (Ctrl+\)
    0x15, // VKILL (Ctrl+U)
    0x1A, // VSUSP (Ctrl+Z)
    0x11, // VSTART (Ctrl+Q)
    0x13, // VSTOP (Ctrl+S)
    0x17, // VWERASE (Ctrl+W)
    0x16, // VLNEXT (Ctrl+V)
    0x12, // VREPRINT (Ctrl+R)
    0x0F, // VDISCARD (Ctrl+O)
};

pub const Options = struct {
    /// True if bracketed paste mode is on.
    bracketed: bool,

    /// Return the encoding options based on the current terminal state.
    pub fn fromTerminal(t: *const Terminal) Options {
        return .{
            .bracketed = t.modes.get(.bracketed_paste),
        };
    }
};

/// Encode the given data for pasting. The resulting value can be written
/// to the pty to perform a paste of the input data.
///
/// The data can be either a `[]u8` or a `[]const u8`. If the data
/// type is const then `EncodeError` may be returned. If the data type
/// is mutable then this function can't return an error.
///
/// This slightly complex calling style allows for initially const
/// data to be passed in without an allocation, since it is rare in normal
/// use cases that the data will need to be modified. In the unlikely case
/// data does need to be modified, the caller can make a mutable copy
/// after seeing the error.
///
/// The data is returned as a set of slices to limit allocations. The caller
/// can combine the slices into a single buffer if desired.
///
/// WARNING: The input data is not checked for safety. See the `isSafe`
/// function to check if the data is safe to paste.
pub fn encode(
    data: anytype,
    opts: Options,
) switch (@TypeOf(data)) {
    []u8 => [3][]const u8,
    []const u8 => Error![3][]const u8,
    else => unreachable,
} {
    const mutable = @TypeOf(data) == []u8;

    var result: [3][]const u8 = .{ "", data, "" };

    // If we have any of the strip values, then we need to replace them
    // with spaces. This is what xterm does and it does it regardless
    // of bracketed paste mode. This is a security measure to prevent pastes
    // from containing bytes that could be used to inject commands.
    if (std.mem.indexOfAny(u8, data, xterm_strip_bytes) != null) {
        if (comptime !mutable) return Error.MutableRequired;
        var offset: usize = 0;
        while (std.mem.indexOfAny(
            u8,
            data[offset..],
            xterm_strip_bytes,
        )) |idx| {
            offset += idx;
            data[offset] = ' ';
            offset += 1;
        }
    }

    // Bracketed paste mode (mode 2004) wraps pasted data in
    // fenceposts so that the terminal can ignore things like newlines.
    if (opts.bracketed) {
        result[0] = "\x1b[200~";
        result[2] = "\x1b[201~";
        return result;
    }

    // Non-bracketed. We have to replace newline with `\r`. This matches
    // the behavior of xterm and other terminals. For `\r\n` this will
    // result in `\r\r` which does match xterm.
    if (comptime mutable) {
        std.mem.replaceScalar(u8, data, '\n', '\r');
    } else if (std.mem.indexOfScalar(u8, data, '\n') != null) {
        return Error.MutableRequired;
    }

    return result;
}

pub const Error = error{
    /// Returned if encoding requires a mutable copy of the data. This
    /// can only be returned if the input data type is const.
    MutableRequired,
};

/// Returns true if the data looks safe to paste. Data is considered
/// unsafe if it contains any of the following:
///
/// - `\n` or `\r`: Line endings can be used to inject commands.
/// - `\x1b[201~`: This is the end of a bracketed paste. This cane be used
///   to exit a bracketed paste and inject commands.
///
/// We consider any scenario unsafe regardless of current terminal state.
/// For example, even if bracketed paste mode is not active, we still
/// consider `\x1b[201~` unsafe. The existence of these types of bytes
/// should raise suspicion that the producer of the paste data is
/// acting strangely.
pub fn isSafe(data: []const u8) bool {
    // Noctty fork: a lone CR submits input in non-bracketed mode.
    return std.mem.indexOf(u8, data, "\n") == null and
        std.mem.indexOf(u8, data, "\r") == null and
        std.mem.indexOf(u8, data, "\x1b[201~") == null;
}

test isSafe {
    const testing = std.testing;
    try testing.expect(isSafe("hello"));
    try testing.expect(!isSafe("hello\n"));
    try testing.expect(!isSafe("hello\nworld"));
    try testing.expect(!isSafe("he\x1b[201~llo"));
}

test "security regression paste rejects carriage return" {
    try std.testing.expect(!isSafe("a\rb"));
}

fn fuzzPasteEncoding(_: void, input: []const u8) !void {
    for ([_]bool{ false, true }) |bracketed| {
        const data = try std.testing.allocator.dupe(u8, input);
        defer std.testing.allocator.free(data);

        const encoded = encode(data, .{ .bracketed = bracketed });
        try std.testing.expect(std.mem.indexOfAny(u8, encoded[1], xterm_strip_bytes) == null);
        try std.testing.expect(std.mem.indexOf(u8, encoded[1], "\x1b[201~") == null);

        if (bracketed) {
            try std.testing.expectEqualStrings("\x1b[200~", encoded[0]);
            try std.testing.expectEqualStrings("\x1b[201~", encoded[2]);
        } else {
            try std.testing.expectEqualStrings("", encoded[0]);
            try std.testing.expectEqualStrings("", encoded[2]);
        }

        if (isSafe(input)) {
            try std.testing.expect(std.mem.indexOfAny(u8, encoded[1], "\n\r") == null);
        }
    }
}

test "fuzz paste sanitizer" {
    try std.testing.fuzz({}, fuzzPasteEncoding, .{ .corpus = &.{
        "plain text",
        "line one\nline two",
        "submit\r",
        "\x00\x03\x1b[201~\x7f",
    } });
}

test "bounded fuzz campaign paste sanitizer" {
    const bounded_fuzz = @import("../testing/bounded_fuzz.zig");
    try bounded_fuzz.run({}, fuzzPasteEncoding, .{
        .random_seed = 0x6B3A_581D_D3E9_2471,
        .corpus = &.{
            "plain text",
            "line one\nline two",
            "submit\r",
            "\x00\x03\x1b[201~\x7f",
        },
    });
}

test "encode bracketed" {
    const testing = std.testing;
    const result = try encode(
        @as([]const u8, "hello"),
        .{ .bracketed = true },
    );
    try testing.expectEqualStrings("\x1b[200~", result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqualStrings("\x1b[201~", result[2]);
}

test "encode unbracketed no newlines" {
    const testing = std.testing;
    const result = try encode(
        @as([]const u8, "hello"),
        .{ .bracketed = false },
    );
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encode unbracketed newlines const" {
    const testing = std.testing;
    try testing.expectError(Error.MutableRequired, encode(
        @as([]const u8, "hello\nworld"),
        .{ .bracketed = false },
    ));
}

test "encode unbracketed newlines" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello\rworld", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encode unbracketed windows-stye newline" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\r\nworld");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello\r\rworld", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encode strip unsafe bytes const" {
    const testing = std.testing;
    try testing.expectError(Error.MutableRequired, encode(
        @as([]const u8, "hello\x00world"),
        .{ .bracketed = true },
    ));
}

test "encode strip unsafe bytes mutable bracketed" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hel\x1blo\x00world");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = true });
    try testing.expectEqualStrings("\x1b[200~", result[0]);
    try testing.expectEqualStrings("hel lo world", result[1]);
    try testing.expectEqualStrings("\x1b[201~", result[2]);
}

test "encode strip unsafe bytes mutable unbracketed" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hel\x03lo");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hel lo", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encode strip multiple unsafe bytes" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "\x00\x08\x7f");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = true });
    try testing.expectEqualStrings("   ", result[1]);
}
