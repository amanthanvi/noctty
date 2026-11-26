const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};

/// Validates a hostname according to [RFC 1123](https://www.rfc-editor.org/rfc/rfc1123)
///
/// std.net.isValidHostname is (currently) too generous. It considers strings like
/// ".example.com", "exa..mple.com", and "-example.com" to be valid hostnames, which
/// is incorrect.
pub fn isValid(hostname: []const u8) bool {
    if (hostname.len == 0) return false;
    if (hostname[0] == '.') return false;

    // Ignore trailing dot (FQDN). It doesn't count toward our length.
    const end = if (hostname[hostname.len - 1] == '.') end: {
        if (hostname.len == 1) return false;
        break :end hostname.len - 1;
    } else hostname.len;

    if (end > 253) return false;

    // Hostnames are divided into dot-separated "labels", which:
    //
    // - Start with a letter or digit
    // - Can contain letters, digits, or hyphens
    // - Must end with a letter or digit
    // - Have a minimum of 1 character and a maximum of 63
    var label_start: usize = 0;
    var label_len: usize = 0;
    for (hostname[0..end], 0..) |c, i| {
        switch (c) {
            '.' => {
                if (label_len == 0 or label_len > 63) return false;
                if (!std.ascii.isAlphanumeric(hostname[label_start])) return false;
                if (!std.ascii.isAlphanumeric(hostname[i - 1])) return false;

                label_start = i + 1;
                label_len = 0;
            },
            '-' => {
                label_len += 1;
            },
            else => {
                if (!std.ascii.isAlphanumeric(c)) return false;
                label_len += 1;
            },
        }
    }

    // Validate the final label
    if (label_len == 0 or label_len > 63) return false;
    if (!std.ascii.isAlphanumeric(hostname[label_start])) return false;
    if (!std.ascii.isAlphanumeric(hostname[end - 1])) return false;

    return true;
}

test isValid {
    const testing = std.testing;

    // Valid hostnames
    try testing.expect(isValid("example"));
    try testing.expect(isValid("example.com"));
    try testing.expect(isValid("www.example.com"));
    try testing.expect(isValid("sub.domain.example.com"));
    try testing.expect(isValid("example.com."));
    try testing.expect(isValid("host-name.example.com."));
    try testing.expect(isValid("123.example.com."));
    try testing.expect(isValid("a-b.com"));
    try testing.expect(isValid("a.b.c.d.e.f.g"));
    try testing.expect(isValid("127.0.0.1")); // Also a valid hostname
    try testing.expect(isValid("a" ** 63 ++ ".com")); // Label exactly 63 chars (valid)
    try testing.expect(isValid("a." ** 126 ++ "a")); // Total length 253 (valid)

    // Invalid hostnames
    try testing.expect(!isValid(""));
    try testing.expect(!isValid(".example.com"));
    try testing.expect(!isValid("example.com.."));
    try testing.expect(!isValid("host..domain"));
    try testing.expect(!isValid("-hostname"));
    try testing.expect(!isValid("hostname-"));
    try testing.expect(!isValid("a.-.b"));
    try testing.expect(!isValid("host_name.com"));
    try testing.expect(!isValid("."));
    try testing.expect(!isValid(".."));
    try testing.expect(!isValid("a" ** 64 ++ ".com")); // Label length 64 (too long)
    try testing.expect(!isValid("a." ** 126 ++ "ab")); // Total length 254 (too long)
}

/// Whether two host names are the same name. Host names are case-insensitive
/// (RFC 4343), and a trailing dot only marks the name as absolute, so
/// `AmanGamingPC.` is `amangamingpc`. The whole name has to match: there is
/// no prefix or label matching, because this answers "is this report from
/// this machine" for OSC 7, where a remote session (ssh) must not pass.
pub fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(stripTrailingDot(a), stripTrailingDot(b));
}

fn stripTrailingDot(name: []const u8) []const u8 {
    if (name.len > 1 and name[name.len - 1] == '.') return name[0 .. name.len - 1];
    return name;
}

/// The names `GetComputerNameExW` can report for this machine.
pub const ComputerName = if (builtin.os.tag == .windows)
    @import("windows_ext.zig").COMPUTER_NAME_FORMAT
else
    void;

/// Room for any computer name in UTF-8: the 256 UTF-16 units `computerName`
/// reads become at most 768 bytes.
pub const computer_name_max = 1024;

/// This machine's name in the given form, written into `buf`, or null when
/// Windows has none (a machine with no DNS name has no `dns_hostname`).
/// Windows only.
pub fn computerName(kind: ComputerName, buf: *[computer_name_max]u8) ?[]const u8 {
    const windows = @import("windows.zig");
    const windows_ext = @import("windows_ext.zig");
    // A DNS name is at most 253 characters and a NetBIOS name 15.
    var wide: [256:0]u16 = undefined;
    var len: windows.DWORD = wide.len;
    if (windows_ext.GetComputerNameExW(kind, &wide, &len) == 0) return null;
    if (len == 0 or len > wide.len) return null;
    const n = std.unicode.utf16LeToUtf8(buf, wide[0..len]) catch return null;
    return buf[0..n];
}

/// Checks if a hostname is local to the current machine. This matches
/// "localhost" and the machine's own name, in any letter case and with or
/// without a trailing dot.
///
/// On Windows the machine has several names. `GetComputerNameA` only gives the
/// NetBIOS name, which is upper-case and cut at 15 characters, while Git Bash,
/// WSL, fish and nushell report the DNS host name (`AmanGamingPC`), so the
/// NetBIOS, DNS host and fully qualified names all count.
pub fn isLocal(hostname: []const u8) LocalHostnameValidationError!bool {
    // A 'localhost' hostname is always considered local.
    if (eql(hostname, "localhost")) return true;

    // If hostname is not "localhost" it must match our hostname.
    switch (builtin.target.os.tag) {
        .windows => {
            // The DNS names first: they are what the shells send.
            const kinds = [_]ComputerName{ .dns_hostname, .dns_fully_qualified, .netbios };
            var buf: [computer_name_max]u8 = undefined;
            for (kinds) |kind| {
                if (computerName(kind, &buf)) |ours| {
                    if (eql(hostname, ours)) return true;
                }
            }
            return false;
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const ourHostname = try posix.gethostname(&buf);
            return eql(hostname, ourHostname);
        },
    }
}

test "eql ignores letter case and one trailing dot" {
    const testing = std.testing;
    try testing.expect(eql("AmanGamingPC", "AMANGAMINGPC"));
    try testing.expect(eql("amangamingpc", "AmanGamingPC"));
    try testing.expect(eql("AmanGamingPC.", "AMANGAMINGPC"));
    try testing.expect(eql("host.example.com.", "HOST.example.COM"));

    // Only the whole name counts: no prefixes, no label matching, no second
    // dot, no empty name.
    try testing.expect(!eql("AmanGaming", "AmanGamingPC"));
    try testing.expect(!eql("AmanGamingPC", "AmanGaming"));
    try testing.expect(!eql("host", "host.example.com"));
    // A NetBIOS name is the first 15 characters, upper-case: it stands for
    // nothing longer, so a longer DNS name needs its own comparison.
    try testing.expect(!eql("AmanGamingPC-Workstation", "AMANGAMINGPC-WOR"));
    try testing.expect(eql("AmanGamingPC-Workstation", "AMANGAMINGPC-WORKSTATION"));
    try testing.expect(!eql("host..", "host"));
    try testing.expect(!eql(".", ""));
    try testing.expect(!eql("", "host"));
}

test "isLocal returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocal("localhost"));
    try std.testing.expect(try isLocal("LOCALHOST"));
    try std.testing.expect(try isLocal("LocalHost."));
}

/// This machine's name for the tests, so none of them names a real machine.
fn testLocalName(buf: *[computer_name_max]u8) ![]const u8 {
    switch (builtin.os.tag) {
        .windows => return computerName(.netbios, buf) orelse error.GetComputerNameFailed,
        else => {
            var host_buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const name = try posix.gethostname(&host_buf);
            @memcpy(buf[0..name.len], name);
            return buf[0..name.len];
        },
    }
}

test "isLocal returns true when hostname is local" {
    var buf: [computer_name_max]u8 = undefined;
    try std.testing.expect(try isLocal(try testLocalName(&buf)));
}

test "isLocal ignores letter case and a trailing dot" {
    var buf: [computer_name_max]u8 = undefined;
    const ours = try testLocalName(&buf);

    var lower: [computer_name_max]u8 = undefined;
    var upper: [computer_name_max]u8 = undefined;
    var alternating: [computer_name_max + 1]u8 = undefined;
    for (ours, 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
        upper[i] = std.ascii.toUpper(c);
        alternating[i] = if (i % 2 == 0) std.ascii.toLower(c) else std.ascii.toUpper(c);
    }
    try std.testing.expect(try isLocal(lower[0..ours.len]));
    try std.testing.expect(try isLocal(upper[0..ours.len]));
    try std.testing.expect(try isLocal(alternating[0..ours.len]));

    // The same name as an absolute DNS name.
    alternating[ours.len] = '.';
    try std.testing.expect(try isLocal(alternating[0 .. ours.len + 1]));
}

test "isLocal returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocal("not-the-local-hostname"),
    );

    // Neither a longer name that starts with ours nor a cut-off form of it.
    var buf: [computer_name_max]u8 = undefined;
    const ours = try testLocalName(&buf);
    var longer: [computer_name_max + 8]u8 = undefined;
    @memcpy(longer[0..ours.len], ours);
    @memcpy(longer[ours.len..][0..8], "-another");
    try std.testing.expectEqual(false, try isLocal(longer[0 .. ours.len + 8]));
    if (ours.len > 1) try std.testing.expectEqual(false, try isLocal(ours[0 .. ours.len - 1]));
}

test "isLocal on Windows also accepts the DNS host name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // The DNS host name is the one Git Bash, WSL, fish and nushell send. It
    // keeps its case and its length, where the NetBIOS name is upper-case and
    // cut at 15 characters. A machine with no DNS name has none to check.
    var buf: [computer_name_max]u8 = undefined;
    const dns = computerName(.dns_hostname, &buf) orelse return error.SkipZigTest;
    try std.testing.expect(try isLocal(dns));

    const lower = try std.ascii.allocLowerString(std.testing.allocator, dns);
    defer std.testing.allocator.free(lower);
    try std.testing.expect(try isLocal(lower));
}
