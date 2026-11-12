//! Reading the connections of a Terminals favorites export (the XML that
//! the Terminals connection manager writes: `<favorites>` holding one
//! `<favorite>` per connection) and the profile Settings makes of each.
//!
//! The fields a profile needs are read: a connection's name, protocol,
//! server, port and user name, and its password. The password never goes
//! into the config file (plain text): Settings keeps it in the Windows
//! Credential Manager (`profile_credentials.zig`), and the export
//! (`writeXml`) writes it back in plain text, as Terminals does. Notes are
//! never read.
//!
//! An SSH connection becomes `ssh -l <user> -p <port> <server>`, an RDP one
//! `mstsc.exe /v:<server>:<port>` (Remote Desktop opens in its own window).
//! Any other protocol (VNC, Telnet, ...) is listed as not importable.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The largest export Settings reads.
pub const max_file_bytes: usize = 16 * 1024 * 1024;

pub const Protocol = enum {
    ssh,
    rdp,
    other,

    fn of(text: []const u8) Protocol {
        if (std.ascii.eqlIgnoreCase(text, "SSH")) return .ssh;
        if (std.ascii.eqlIgnoreCase(text, "RDP")) return .rdp;
        return .other;
    }
};

pub const Favorite = struct {
    /// The connection's name in Terminals (may be empty).
    name: []const u8,
    /// The protocol as written (`RDP`, `SSH`, `VNC`, ...).
    protocol_text: []const u8,
    protocol: Protocol,
    server: []const u8,
    /// Null when the export has none or it is not a port number.
    port: ?u16,
    user: []const u8,
    /// As written, entities decoded, not trimmed. Empty for none.
    password: []const u8 = "",
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    favorites: []const Favorite,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

pub const ParseError = Allocator.Error || error{ NotTerminalsExport, NotText };

/// The connections of a Terminals export, in the file's order. `bytes` is
/// the file as read: UTF-8 (with or without a BOM) or UTF-16 LE with a BOM.
pub fn parse(alloc: Allocator, bytes: []const u8) ParseError!Parsed {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const text = try asUtf8(a, bytes);
    if (std.mem.indexOf(u8, text, "<favorites") == null) return error.NotTerminalsExport;

    var favorites: std.ArrayListUnmanaged(Favorite) = .empty;
    var at: usize = 0;
    while (nextElement(text, "favorite", at)) |found| {
        at = found.end;
        const body = found.body;
        const protocol_text = try field(a, body, "protocol");
        const port_text = try field(a, body, "port");
        try favorites.append(a, .{
            .name = try field(a, body, "name"),
            .protocol_text = protocol_text,
            .protocol = .of(protocol_text),
            .server = try field(a, body, "serverName"),
            .port = std.fmt.parseInt(u16, port_text, 10) catch null,
            .user = try field(a, body, "userName"),
            .password = if (nextElement(body, "password", 0)) |pw| try decode(a, pw.body) else "",
        });
    }
    return .{ .arena = arena, .favorites = favorites.items };
}

fn asUtf8(a: Allocator, bytes: []const u8) ParseError![]const u8 {
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE) {
        const units = (bytes.len - 2) / 2;
        const wide = try a.alloc(u16, units);
        for (wide, 0..) |*unit, i| unit.* = std.mem.readInt(u16, bytes[2 + i * 2 ..][0..2], .little);
        return std.unicode.utf16LeToUtf8Alloc(a, wide) catch error.NotText;
    }
    const text = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
    if (!std.unicode.utf8ValidateSlice(text)) return error.NotText;
    return text;
}

const Element = struct { body: []const u8, end: usize };

/// The next `<tag>...</tag>` (or `<tag />`) at or after `from`: its content
/// and the index past it. `<tag` must be followed by `>`, `/` or white space,
/// so `<favorite>` is not found inside `<favorites>`.
fn nextElement(text: []const u8, comptime tag: []const u8, from: usize) ?Element {
    var at = from;
    while (std.mem.indexOfPos(u8, text, at, "<" ++ tag)) |start| {
        const after = start + 1 + tag.len;
        at = after;
        if (after >= text.len) return null;
        switch (text[after]) {
            '>', '/', ' ', '\t', '\r', '\n' => {},
            else => continue,
        }
        const open_end = std.mem.indexOfScalarPos(u8, text, after, '>') orelse return null;
        if (text[open_end - 1] == '/') return .{ .body = "", .end = open_end + 1 };
        const close = std.mem.indexOfPos(u8, text, open_end + 1, "</" ++ tag ++ ">") orelse return null;
        return .{ .body = text[open_end + 1 .. close], .end = close + tag.len + 3 };
    }
    return null;
}

/// Child element `tag`'s text, entities decoded and trimmed; empty when the
/// element is missing or empty.
fn field(a: Allocator, body: []const u8, comptime tag: []const u8) Allocator.Error![]const u8 {
    const found = nextElement(body, tag, 0) orelse return "";
    return decode(a, std.mem.trim(u8, found.body, &std.ascii.whitespace));
}

/// XML's five named entities and numeric references; anything else is kept
/// as written.
fn decode(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') if (std.mem.indexOfScalarPos(u8, text, i, ';')) |semi| {
            const name = text[i + 1 .. semi];
            const named: ?u8 = if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else null;
            if (named) |byte| {
                try out.append(a, byte);
                i = semi + 1;
                continue;
            }
            if (name.len > 1 and name[0] == '#') {
                const code = if (name[1] == 'x' or name[1] == 'X')
                    std.fmt.parseInt(u21, name[2..], 16) catch null
                else
                    std.fmt.parseInt(u21, name[1..], 10) catch null;
                if (code) |cp| {
                    var buf: [4]u8 = undefined;
                    if (std.unicode.utf8Encode(cp, &buf)) |len| {
                        try out.appendSlice(a, buf[0..len]);
                        i = semi + 1;
                        continue;
                    } else |_| {}
                }
            }
        };
        try out.append(a, text[i]);
        i += 1;
    }
    return out.items;
}

/// Why a connection cannot become a profile.
pub const Refusal = enum {
    protocol,
    no_server,
    characters,

    pub fn text(self: Refusal) []const u8 {
        return switch (self) {
            .protocol => "protocol not supported",
            .no_server => "no server",
            .characters => "server or user has characters a command line cannot hold",
        };
    }
};

/// Whether `favorite` can become a profile, and if not why.
pub fn refusal(favorite: Favorite) ?Refusal {
    if (favorite.protocol == .other) return .protocol;
    if (favorite.server.len == 0) return .no_server;
    if (!safeHost(favorite.server)) return .characters;
    if (favorite.protocol == .ssh and favorite.user.len != 0 and !safeUser(favorite.user)) return .characters;
    return null;
}

/// A host name, an IPv4 address or an IPv6 one (bracketed or not).
fn safeHost(host: []const u8) bool {
    if (host.len > 255) return false;
    for (host) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', ':', '[', ']' => {},
        else => return false,
    };
    return host[0] != '-';
}

/// A user name with nothing a command line or koreterm's `%VAR%` expansion
/// would read: no quotes, `%`, control characters or white space.
fn safeUser(user: []const u8) bool {
    if (user.len > 256 or user[0] == '-') return false;
    if (!std.unicode.utf8ValidateSlice(user)) return false;
    for (user) |byte| switch (byte) {
        0...0x20, 0x7F, '"', '%', '^', '&', '|', '<', '>' => return false,
        else => {},
    };
    return true;
}

/// The profile's command line for `favorite`, which `refusal` accepts.
pub fn writeCommand(writer: *std.Io.Writer, favorite: Favorite) std.Io.Writer.Error!void {
    std.debug.assert(refusal(favorite) == null);
    switch (favorite.protocol) {
        .ssh => {
            try writer.writeAll("ssh");
            if (favorite.user.len != 0) try writer.print(" -l {s}", .{favorite.user});
            if (favorite.port) |port| if (port != 22) try writer.print(" -p {d}", .{port});
            try writer.print(" {s}", .{favorite.server});
        },
        .rdp => try writeRdpCommand(writer, favorite.server, favorite.port orelse 3389, .{}),
        .other => unreachable,
    }
}

pub fn allocCommand(a: Allocator, favorite: Favorite) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    writeCommand(&out.writer, favorite) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The longest id `baseId` writes, so a `-NN` suffix still fits in 64.
pub const max_base_len = 56;

/// A profile id made from `name`: lower case ASCII letters and digits, with
/// Latin accents dropped (`São` is `sao`), and one `-` for every run of
/// anything else. `fallback` when nothing is left. Written into `buf`.
pub fn baseId(buf: *[max_base_len]u8, name: []const u8, fallback: []const u8) []const u8 {
    var len: usize = 0;
    var dash = false;
    var view = std.unicode.Utf8View.init(name) catch std.unicode.Utf8View.initUnchecked("");
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const byte: ?u8 = if (cp < 0x80) ascii: {
            const c: u8 = @intCast(cp);
            break :ascii if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_') std.ascii.toLower(c) else null;
        } else unaccent(cp);
        if (byte) |c| {
            if (dash and len != 0 and len < buf.len) {
                buf[len] = '-';
                len += 1;
            }
            dash = false;
            if (len == buf.len) break;
            buf[len] = c;
            len += 1;
        } else dash = true;
    }
    while (len != 0 and (buf[len - 1] == '.' or buf[len - 1] == '-')) len -= 1;
    var start: usize = 0;
    while (start < len and buf[start] == '.') start += 1;
    if (start == len) {
        const n = @min(fallback.len, buf.len);
        @memcpy(buf[0..n], fallback[0..n]);
        return buf[0..n];
    }
    return buf[start..len];
}

/// The ASCII letter a Latin-1 accented letter is written with, lower case.
fn unaccent(cp: u21) ?u8 {
    return switch (cp) {
        0xC0...0xC5, 0xE0...0xE5 => 'a',
        0xC7, 0xE7 => 'c',
        0xC8...0xCB, 0xE8...0xEB => 'e',
        0xCC...0xCF, 0xEC...0xEF => 'i',
        0xD1, 0xF1 => 'n',
        0xD2...0xD6, 0xD8, 0xF2...0xF6, 0xF8 => 'o',
        0xD9...0xDC, 0xF9...0xFC => 'u',
        0xDD, 0xFD, 0xFF => 'y',
        else => null,
    };
}

/// The protocol's word for an id with nothing else to go on, and for a list.
pub fn protocolWord(favorite: Favorite) []const u8 {
    return switch (favorite.protocol) {
        .ssh => "ssh",
        .rdp => "rdp",
        .other => "other",
    };
}

/// A profile's command line read back as a connection: the forms
/// `writeCommand` writes (`ssh [-l user] [-p port] host`, `ssh user@host`,
/// `mstsc.exe /v:host[:port]`). Null for any other command line.
pub const Connection = struct {
    protocol: Protocol,
    server: []const u8,
    port: u16,
    user: []const u8 = "",
    /// RDP only: this connection's own quality settings, written after
    /// `/v:` as `/colors:<bits>`, `/compression:on|off` and
    /// `/experience:fast|balanced|rich`; null takes the config's
    /// (`rdp-color-depth`, `rdp-compression`, `rdp-experience`).
    rdp: RdpOptions = .{},
};

pub const ColorDepth = enum(u8) { @"15" = 15, @"16" = 16, @"24" = 24, @"32" = 32 };
pub const Experience = enum { fast, balanced, rich };

pub const RdpOptions = struct {
    colors: ?ColorDepth = null,
    compression: ?bool = null,
    experience: ?Experience = null,
    /// `/certificates:trust|ask` (`rdp-trust-certificates`).
    trust_certificates: ?bool = null,
};

/// The command line of an RDP connection: `mstsc.exe /v:<server>[:<port>]`
/// and its own options. koreterm never starts it: a Remote Desktop tab reads
/// it back (`parseCommand`).
pub fn writeRdpCommand(writer: *std.Io.Writer, server: []const u8, port: u16, options: RdpOptions) std.Io.Writer.Error!void {
    try writer.print("mstsc.exe /v:{s}", .{server});
    if (port != 3389) try writer.print(":{d}", .{port});
    if (options.colors) |colors| try writer.print(" /colors:{d}", .{@intFromEnum(colors)});
    if (options.compression) |on| try writer.print(" /compression:{s}", .{if (on) "on" else "off"});
    if (options.experience) |experience| try writer.print(" /experience:{t}", .{experience});
    if (options.trust_certificates) |trust| try writer.print(" /certificates:{s}", .{if (trust) "trust" else "ask"});
}

/// Whether `server` can go on a command line as a host (`safeHost`).
pub fn validServer(server: []const u8) bool {
    return server.len != 0 and safeHost(server);
}

/// `/name:value` when `arg` is that option (any case), else null.
fn optionValue(arg: []const u8, comptime name: []const u8) ?[]const u8 {
    const prefix = "/" ++ name ++ ":";
    if (arg.len <= prefix.len or !std.ascii.eqlIgnoreCase(arg[0..prefix.len], prefix)) return null;
    return arg[prefix.len..];
}

pub fn parseCommand(command: []const u8) ?Connection {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    const program = it.next() orelse return null;
    const base = std.fs.path.basenameWindows(program);
    if (std.ascii.eqlIgnoreCase(base, "ssh") or std.ascii.eqlIgnoreCase(base, "ssh.exe")) {
        var conn: Connection = .{ .protocol = .ssh, .server = "", .port = 22 };
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "-l")) {
                conn.user = it.next() orelse return null;
            } else if (std.mem.eql(u8, arg, "-p")) {
                conn.port = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
            } else if (arg[0] == '-') {
                return null;
            } else {
                // A second word is a remote command: not a plain connection.
                if (conn.server.len != 0) return null;
                if (std.mem.lastIndexOfScalar(u8, arg, '@')) |at| {
                    if (conn.user.len == 0) conn.user = arg[0..at];
                    conn.server = arg[at + 1 ..];
                } else conn.server = arg;
            }
        }
        if (conn.server.len == 0) return null;
        return conn;
    }
    if (std.ascii.eqlIgnoreCase(base, "mstsc") or std.ascii.eqlIgnoreCase(base, "mstsc.exe")) {
        var conn: Connection = .{ .protocol = .rdp, .server = "", .port = 3389 };
        while (it.next()) |arg| {
            if (optionValue(arg, "colors")) |value| {
                const bits = std.fmt.parseInt(u8, value, 10) catch continue;
                conn.rdp.colors = std.enums.fromInt(ColorDepth, bits);
                continue;
            }
            if (optionValue(arg, "compression")) |value| {
                if (std.ascii.eqlIgnoreCase(value, "on")) conn.rdp.compression = true;
                if (std.ascii.eqlIgnoreCase(value, "off")) conn.rdp.compression = false;
                continue;
            }
            if (optionValue(arg, "certificates")) |value| {
                if (std.ascii.eqlIgnoreCase(value, "trust")) conn.rdp.trust_certificates = true;
                if (std.ascii.eqlIgnoreCase(value, "ask")) conn.rdp.trust_certificates = false;
                continue;
            }
            if (optionValue(arg, "experience")) |value| {
                inline for (comptime std.enums.values(Experience)) |experience| {
                    if (std.ascii.eqlIgnoreCase(value, @tagName(experience))) conn.rdp.experience = experience;
                }
                continue;
            }
            if (arg.len > 3 and std.ascii.eqlIgnoreCase(arg[0..3], "/v:")) {
                const target = arg[3..];
                // `host:port`; an unbracketed IPv6 address has many colons.
                const many = std.mem.count(u8, target, ":") > 1 and target[0] != '[';
                if (std.mem.lastIndexOfScalar(u8, target, ':')) |colon| if (!many) {
                    conn.server = target[0..colon];
                    conn.port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch return null;
                    continue;
                };
                conn.server = target;
            }
        }
        if (conn.server.len == 0) return null;
        return conn;
    }
    return null;
}

/// A connection the export writes.
pub const ExportEntry = struct {
    name: []const u8,
    connection: Connection,
    password: []const u8 = "",
};

/// A Terminals favorites file holding `entries`, passwords in plain text.
pub fn writeXml(writer: *std.Io.Writer, entries: []const ExportEntry) std.Io.Writer.Error!void {
    try writer.writeAll("\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<favorites>\r\n");
    for (entries) |entry| {
        const conn = entry.connection;
        const word: []const u8 = switch (conn.protocol) {
            .ssh => "SSH",
            .rdp => "RDP",
            .other => unreachable,
        };
        const scheme: []const u8 = if (conn.protocol == .ssh) "ssh" else "rdp";
        try writer.writeAll("  <favorite>\r\n");
        try writer.print("    <protocol>{s}</protocol>\r\n    <port>{d}</port>\r\n", .{ word, conn.port });
        try element(writer, "serverName", conn.server);
        try writer.print("    <url>{s}://", .{scheme});
        try escape(writer, conn.server);
        try writer.print(":{d}/</url>\r\n", .{conn.port});
        try element(writer, "name", entry.name);
        try writer.writeAll("    <notes />\r\n    <tags />\r\n    <newWindow>False</newWindow>\r\n    <toolBarIcon />\r\n");
        try writer.print("    <bitmapPeristence>{s}</bitmapPeristence>\r\n    <credential />\r\n    <domainName />\r\n", .{word});
        try element(writer, "userName", conn.user);
        try element(writer, "password", entry.password);
        try writer.writeAll("  </favorite>\r\n");
    }
    try writer.writeAll("</favorites>\r\n");
}

fn element(writer: *std.Io.Writer, comptime tag: []const u8, text: []const u8) std.Io.Writer.Error!void {
    if (text.len == 0) return writer.writeAll("    <" ++ tag ++ " />\r\n");
    try writer.writeAll("    <" ++ tag ++ ">");
    try escape(writer, text);
    try writer.writeAll("</" ++ tag ++ ">\r\n");
}

fn escape(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(byte),
    };
}

test "an RDP command line carries the connection's own quality settings" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeRdpCommand(&writer, "srv", 5589, .{ .colors = .@"16", .compression = false, .experience = .fast, .trust_certificates = false });
    try std.testing.expectEqualStrings("mstsc.exe /v:srv:5589 /colors:16 /compression:off /experience:fast /certificates:ask", writer.buffered());
    const conn = parseCommand(writer.buffered()).?;
    try std.testing.expectEqualStrings("srv", conn.server);
    try std.testing.expectEqual(@as(u16, 5589), conn.port);
    try std.testing.expectEqual(@as(?ColorDepth, .@"16"), conn.rdp.colors);
    try std.testing.expectEqual(@as(?bool, false), conn.rdp.compression);
    try std.testing.expectEqual(@as(?Experience, .fast), conn.rdp.experience);
    try std.testing.expectEqual(@as(?bool, false), conn.rdp.trust_certificates);
    // None given: the config decides; an unknown value is ignored.
    const plain = parseCommand("mstsc.exe /v:srv /colors:7").?;
    try std.testing.expect(plain.rdp.colors == null and plain.rdp.compression == null and plain.rdp.experience == null);
}

test "parseCommand reads back what writeCommand writes" {
    const a = std.testing.allocator;
    const cases = [_]Favorite{
        .{ .name = "", .protocol_text = "SSH", .protocol = .ssh, .server = "h.example", .port = 2200, .user = "me@jump" },
        .{ .name = "", .protocol_text = "SSH", .protocol = .ssh, .server = "1.2.3.4", .port = 22, .user = "" },
        .{ .name = "", .protocol_text = "RDP", .protocol = .rdp, .server = "38.0.0.1", .port = 5589, .user = "x" },
        .{ .name = "", .protocol_text = "RDP", .protocol = .rdp, .server = "srv", .port = 3389, .user = "" },
    };
    for (cases) |fav| {
        const cmd = try allocCommand(a, fav);
        defer a.free(cmd);
        const conn = parseCommand(cmd).?;
        try std.testing.expectEqual(fav.protocol, conn.protocol);
        try std.testing.expectEqualStrings(fav.server, conn.server);
        try std.testing.expectEqual(fav.port.?, conn.port);
        if (fav.protocol == .ssh) try std.testing.expectEqualStrings(fav.user, conn.user);
    }
    try std.testing.expectEqualStrings("root", parseCommand("ssh root@host").?.user);
    try std.testing.expect(parseCommand("pwsh.exe -NoLogo") == null);
    try std.testing.expect(parseCommand("ssh host uptime") == null);
}

test "writeXml round-trips through parse, password and all" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeXml(&out.writer, &.{
        .{ .name = "Box & <Co>", .connection = .{ .protocol = .ssh, .server = "h", .port = 2200, .user = "root" }, .password = "p&ss<\"x'>" },
        .{ .name = "Desk", .connection = .{ .protocol = .rdp, .server = "10.0.0.5", .port = 3389 } },
    });
    var parsed = try parse(a, out.written());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.favorites.len);
    try std.testing.expectEqualStrings("Box & <Co>", parsed.favorites[0].name);
    try std.testing.expectEqualStrings("p&ss<\"x'>", parsed.favorites[0].password);
    try std.testing.expectEqual(@as(?u16, 2200), parsed.favorites[0].port);
    try std.testing.expectEqual(Protocol.rdp, parsed.favorites[1].protocol);
    try std.testing.expectEqualStrings("", parsed.favorites[1].password);
}

test "parse reads the fields a profile needs and skips the rest" {
    const xml =
        "\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n" ++
        "<favorites>\r\n" ++
        "  <favorite>\r\n    <protocol>SSH</protocol>\r\n    <port>2222</port>\r\n" ++
        "    <serverName>host.example</serverName>\r\n    <name>Box &amp; Co</name>\r\n" ++
        "    <notes>secret &lt;notes&gt;</notes>\r\n    <tags />\r\n" ++
        "    <userName>root</userName>\r\n    <password>hunter2</password>\r\n  </favorite>\r\n" ++
        "  <favorite>\r\n    <protocol>RDP</protocol>\r\n    <port>3389</port>\r\n" ++
        "    <serverName>10.0.0.5</serverName>\r\n    <name>S&#227;o Paulo</name>\r\n" ++
        "    <domainName />\r\n    <userName>adm</userName>\r\n  </favorite>\r\n" ++
        "  <favorite><protocol>VNC</protocol><port>5900</port><serverName>v</serverName><name>V</name></favorite>\r\n" ++
        "</favorites>\r\n";
    var parsed = try parse(std.testing.allocator, xml);
    defer parsed.deinit();
    const favs = parsed.favorites;
    try std.testing.expectEqual(@as(usize, 3), favs.len);
    try std.testing.expectEqualStrings("Box & Co", favs[0].name);
    try std.testing.expectEqual(Protocol.ssh, favs[0].protocol);
    try std.testing.expectEqual(@as(?u16, 2222), favs[0].port);
    try std.testing.expectEqualStrings("root", favs[0].user);
    try std.testing.expectEqualStrings("hunter2", favs[0].password);
    try std.testing.expectEqualStrings("São Paulo", favs[1].name);
    try std.testing.expectEqual(Protocol.rdp, favs[1].protocol);
    try std.testing.expectEqual(Protocol.other, favs[2].protocol);
    try std.testing.expectEqualStrings("VNC", favs[2].protocol_text);
    try std.testing.expectEqual(@as(usize, 0), favs[2].user.len);
}

test "parse refuses a file that is no Terminals export" {
    try std.testing.expectError(error.NotTerminalsExport, parse(std.testing.allocator, "<config></config>"));
    try std.testing.expectError(error.NotText, parse(std.testing.allocator, "<favorites>\xFF</favorites>"));
}

test "parse reads a UTF-16 export" {
    const utf8 = "<favorites><favorite><protocol>RDP</protocol><serverName>h</serverName><name>N</name></favorite></favorites>";
    var buf: [2 + utf8.len * 2]u8 = undefined;
    buf[0] = 0xFF;
    buf[1] = 0xFE;
    for (utf8, 0..) |byte, i| {
        buf[2 + i * 2] = byte;
        buf[3 + i * 2] = 0;
    }
    var parsed = try parse(std.testing.allocator, &buf);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.favorites.len);
    try std.testing.expectEqualStrings("h", parsed.favorites[0].server);
}

test "commands for SSH and RDP, default ports left out" {
    const a = std.testing.allocator;
    const ssh: Favorite = .{ .name = "x", .protocol_text = "SSH", .protocol = .ssh, .server = "1.2.3.4", .port = 2200, .user = "me@jump.example" };
    const ssh_cmd = try allocCommand(a, ssh);
    defer a.free(ssh_cmd);
    try std.testing.expectEqualStrings("ssh -l me@jump.example -p 2200 1.2.3.4", ssh_cmd);

    var plain = ssh;
    plain.port = 22;
    plain.user = "";
    const plain_cmd = try allocCommand(a, plain);
    defer a.free(plain_cmd);
    try std.testing.expectEqualStrings("ssh 1.2.3.4", plain_cmd);

    const rdp: Favorite = .{ .name = "x", .protocol_text = "RDP", .protocol = .rdp, .server = "srv.local", .port = 5589, .user = "u" };
    const rdp_cmd = try allocCommand(a, rdp);
    defer a.free(rdp_cmd);
    try std.testing.expectEqualStrings("mstsc.exe /v:srv.local:5589", rdp_cmd);

    var rdp_default = rdp;
    rdp_default.port = 3389;
    const rdp_default_cmd = try allocCommand(a, rdp_default);
    defer a.free(rdp_default_cmd);
    try std.testing.expectEqualStrings("mstsc.exe /v:srv.local", rdp_default_cmd);
}

test "refusal: other protocols, no server, unsafe characters" {
    const base: Favorite = .{ .name = "x", .protocol_text = "SSH", .protocol = .ssh, .server = "h", .port = null, .user = "" };
    try std.testing.expectEqual(@as(?Refusal, null), refusal(base));
    var f = base;
    f.protocol = .other;
    try std.testing.expectEqual(@as(?Refusal, .protocol), refusal(f));
    f = base;
    f.server = "";
    try std.testing.expectEqual(@as(?Refusal, .no_server), refusal(f));
    f = base;
    f.server = "h & calc";
    try std.testing.expectEqual(@as(?Refusal, .characters), refusal(f));
    f = base;
    f.server = "-oProxyCommand=x";
    try std.testing.expectEqual(@as(?Refusal, .characters), refusal(f));
    f = base;
    f.user = "%USERNAME%";
    try std.testing.expectEqual(@as(?Refusal, .characters), refusal(f));
    f = base;
    f.user = "a b";
    try std.testing.expectEqual(@as(?Refusal, .characters), refusal(f));
}

test "baseId lowers, drops accents and joins the rest with one dash" {
    var buf: [max_base_len]u8 = undefined;
    try std.testing.expectEqualStrings("coletor-nf", baseId(&buf, "Coletor NF", "rdp"));
    try std.testing.expectEqualStrings("sao-paulo", baseId(&buf, "  São   Paulo!! ", "rdp"));
    try std.testing.expectEqualStrings("_linode", baseId(&buf, "_Linode", "ssh"));
    try std.testing.expectEqualStrings("rdp", baseId(&buf, "★★", "rdp"));
    try std.testing.expectEqualStrings("rdp", baseId(&buf, "", "rdp"));
    const long = "a" ** 100;
    try std.testing.expectEqual(@as(usize, max_base_len), baseId(&buf, long, "rdp").len);
}
