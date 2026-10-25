//! What a log line may say about a command, an argument or a directory.
//!
//! A log is kept, copied into bug reports and read by other people. A command
//! line holds tokens and an argument can be a password; a directory names the
//! user. A line that has to mention one says how much there is, not what:
//! `<14 bytes>`, `<3 args, 57 bytes>`. That is enough to tell a missing value
//! from an empty one, which is most of what a log is read for.
//!
//! Use these in a log call where the value itself would go:
//!
//!     log.info("launch cwd={f}", .{redact.bytes(cwd)});
//!
//! The program a launch runs is not a secret and may still be logged by path
//! (`started subcommand path=`); its arguments may not.

const std = @import("std");

/// One string: `<N bytes>`.
pub const Bytes = struct {
    len: usize,

    pub fn format(self: Bytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("<{d} bytes>", .{self.len});
    }
};

pub fn bytes(value: []const u8) Bytes {
    return .{ .len = value.len };
}

/// A string that may be absent: `unset`, or `<N bytes>`.
pub const OptionalBytes = struct {
    len: ?usize,

    pub fn format(self: OptionalBytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const len = self.len orelse return writer.writeAll("unset");
        try writer.print("<{d} bytes>", .{len});
    }
};

pub fn optionalBytes(value: ?[]const u8) OptionalBytes {
    return .{ .len = if (value) |v| v.len else null };
}

/// A list of arguments: `<N args, M bytes>`.
pub const Args = struct {
    count: usize,
    len: usize,

    pub fn format(self: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("<{d} args, {d} bytes>", .{ self.count, self.len });
    }
};

/// `list` is any slice of byte strings (`[]const [:0]const u8` and
/// `[]const []const u8` among them).
pub fn argv(list: anytype) Args {
    var len: usize = 0;
    for (list) |arg| len += arg.len;
    return .{ .count = list.len, .len = len };
}

test "a redacted value says how much there was and nothing else" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;

    const secret = "hunter2";
    try testing.expectEqualStrings("<7 bytes>", try std.fmt.bufPrint(&buf, "{f}", .{bytes(secret)}));
    try testing.expectEqualStrings("<0 bytes>", try std.fmt.bufPrint(&buf, "{f}", .{bytes("")}));

    const some: ?[]const u8 = secret;
    const none: ?[]const u8 = null;
    try testing.expectEqualStrings("<7 bytes>", try std.fmt.bufPrint(&buf, "{f}", .{optionalBytes(some)}));
    try testing.expectEqualStrings("unset", try std.fmt.bufPrint(&buf, "{f}", .{optionalBytes(none)}));

    const sentinel_args = [_][:0]const u8{ "tool.exe", "--token=abc", "x" };
    try testing.expectEqualStrings("<3 args, 20 bytes>", try std.fmt.bufPrint(&buf, "{f}", .{argv(&sentinel_args)}));
    const plain_args = [_][]const u8{ "a", "bc" };
    try testing.expectEqualStrings("<2 args, 3 bytes>", try std.fmt.bufPrint(&buf, "{f}", .{argv(&plain_args)}));
    try testing.expectEqualStrings("<0 args, 0 bytes>", try std.fmt.bufPrint(&buf, "{f}", .{argv(&[_][]const u8{})}));

    // Neither the value nor a decimal or hex form of it is in the text.
    const text = try std.fmt.bufPrint(&buf, "{f} {f} {f}", .{ bytes(secret), optionalBytes(some), argv(&sentinel_args) });
    try testing.expect(std.mem.indexOf(u8, text, "hunter") == null);
    try testing.expect(std.mem.indexOf(u8, text, "104, 117") == null);
    try testing.expect(std.mem.indexOf(u8, text, "68 75") == null);
}
