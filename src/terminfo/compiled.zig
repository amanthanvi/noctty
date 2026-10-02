//! Compiled terminfo: the binary format that `tic` writes and ncurses reads.
//! See term(5): https://invisible-island.net/ncurses/man/term.5.html
//!
//! Windows has no `tic`, so the Windows build compiles our entry with this
//! encoder. For a source written with short capability names, as ours is, it
//! writes the same bytes as ncurses 6 `tic -x`; the tests pin that against
//! entries compiled by tic. It does not know tic's aliases (`kbtab` for `kcbt`)
//! or long names (`auto_right_margin`), stores them as extended capabilities,
//! and does not check extended names against ncurses' table of known
//! extensions. An extended number above 32767 makes it write 32-bit numbers,
//! where tic writes 16-bit ones and truncates it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Source = @import("Source.zig");
const caps = @import("caps.zig");

/// Magic number of the legacy format, whose numbers are 16-bit.
const magic_legacy: i32 = 0o432;

/// Magic number of the ncurses 6.1 format, whose numbers are 32-bit. tic only
/// writes it when a number does not fit in 16 bits.
const magic_32bit: i32 = 0o1036;

/// The size of the header every compiled entry starts with: six 16-bit
/// values, the first of them the magic number.
const header_size = 12;

/// Whether `bytes` hold a whole compiled entry, as far as its header tells:
/// a known magic number, and the names, booleans, numbers, string offsets and
/// string table the header declares all present. ncurses rejects a file that
/// ends before them. The extended section that may follow is not checked.
pub fn isEntry(bytes: []const u8) bool {
    if (bytes.len < header_size) return false;
    const magic = std.mem.readInt(u16, bytes[0..2], .little);
    const number_size: usize = if (magic == magic_legacy)
        2
    else if (magic == magic_32bit)
        4
    else
        return false;

    var counts: [5]usize = undefined;
    for (&counts, 0..) |*count, i| {
        const offset = 2 + i * 2;
        const value = std.mem.readInt(i16, bytes[offset..][0..2], .little);
        if (value < 0) return false;
        count.* = @intCast(value);
    }
    const names, const booleans, const numbers, const strings, const table = counts;

    var size = header_size + names + booleans;
    if (size % 2 != 0) size += 1;
    size += numbers * number_size + strings * 2 + table;
    return bytes.len >= size;
}

/// ncurses 6.1 and later read entries up to this size.
pub const max_entry_size = 32768;

/// The longest names line tic writes (MAX_NAME_SIZE), excluding its NUL.
const max_names_size = 512;

/// The values of an absent and a canceled number or string offset.
const absent: i32 = -1;
const canceled: i32 = -2;

pub const Error = error{
    /// A capability appears more than once.
    DuplicateCapability,

    /// A predefined capability has a value of the wrong type.
    TypeMismatch,

    /// `use` names another entry, which this encoder cannot resolve.
    UnsupportedUse,

    /// A string value contains a NUL or a newline, or ends inside an escape.
    InvalidString,

    /// A terminal name is empty or contains a character that cannot be part
    /// of a file name.
    InvalidName,

    /// A number does not fit in the 32-bit format.
    NumberTooLarge,

    /// The names line or the whole entry exceeds what ncurses reads.
    EntryTooLarge,
} || Allocator.Error || std.Io.Writer.Error;

/// Encode `source` as a compiled terminfo entry.
pub fn encode(alloc: Allocator, source: Source, writer: *std.Io.Writer) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry: Entry = try .init(arena, source);
    var out: std.Io.Writer.Allocating = .init(arena);
    try entry.write(&out.writer);
    if (out.written().len > max_entry_size) return error.EntryTooLarge;
    try writer.writeAll(out.written());
}

/// Write `source` into the terminfo database directory `dir`, one file per
/// name in fileNames, each in the directory hexDir names.
pub fn writeDatabase(alloc: Allocator, source: Source, dir: std.fs.Dir) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try encode(alloc, source, &out.writer);

    for (try fileNames(source)) |name| {
        const hex = hexDir(name);
        var sub_dir = try dir.makeOpenPath(&hex, .{});
        defer sub_dir.close();
        try sub_dir.writeFile(.{ .sub_path = name, .data = out.written() });
    }
}

/// The names of `source` that get a file in a database. The last of several
/// names is a description, as in terminfo(5), and gets none.
pub fn fileNames(source: Source) Error![]const []const u8 {
    const names = if (source.names.len > 1)
        source.names[0 .. source.names.len - 1]
    else
        source.names;
    for (names) |name| try validateFileName(name);
    return names;
}

/// The directory, inside a database, that holds the file for `name`: the hex
/// code of its first character (`78` for `xterm-ghostty`). That is the layout
/// ncurses uses on case-insensitive file systems and the only one its ports
/// on Windows (MSYS2, Cygwin) read. `name` must not be empty.
pub fn hexDir(name: []const u8) [2]u8 {
    var buf: [2]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>2}", .{name[0]}) catch unreachable;
    return buf;
}

fn validateFileName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidName;
    for (name) |c| switch (c) {
        // Path separators and the characters Windows forbids in file names.
        '/', '\\', ':', '*', '?', '"', '<', '>', '|' => return error.InvalidName,
        else => if (c < 0x20 or c == 0x7f) return error.InvalidName,
    };
}

/// A string capability's value as tic stores it.
const String = union(enum) {
    absent,
    canceled,
    value: []const u8,
};

/// An extended (user-defined) capability. ncurses keeps each type's
/// extended names sorted, and tic writes them in that order.
const Extended = struct {
    name: []const u8,
    value: union(enum) {
        boolean,
        numeric: i32,
        string: String,
    },

    fn lessThan(_: void, a: Extended, b: Extended) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

const Entry = struct {
    names: []const u8,
    booleans: [caps.booleans.len]bool = @splat(false),
    numbers: [caps.numbers.len]i32 = @splat(absent),
    strings: [caps.strings.len]String = @splat(.absent),
    ext_booleans: []const Extended = &.{},
    ext_numbers: []const Extended = &.{},
    ext_strings: []const Extended = &.{},

    fn init(arena: Allocator, source: Source) Error!Entry {
        if (source.names.len == 0) return error.InvalidName;
        for (source.names) |name| {
            // `|` separates the names, so it cannot be part of one.
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '|') != null) {
                return error.InvalidName;
            }
        }
        var self: Entry = .{ .names = try std.mem.join(arena, "|", source.names) };
        if (self.names.len > max_names_size) return error.EntryTooLarge;

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var ext_booleans: std.ArrayList(Extended) = .empty;
        var ext_numbers: std.ArrayList(Extended) = .empty;
        var ext_strings: std.ArrayList(Extended) = .empty;

        for (source.capabilities) |cap| {
            if (std.mem.eql(u8, cap.name, "use")) return error.UnsupportedUse;
            const gop = try seen.getOrPut(arena, cap.name);
            if (gop.found_existing) return error.DuplicateCapability;

            const bool_idx = indexOf(&caps.booleans, cap.name);
            const num_idx = indexOf(&caps.numbers, cap.name);
            const str_idx = indexOf(&caps.strings, cap.name);
            switch (cap.value) {
                // A canceled boolean is simply false. tic cannot know the type
                // of a canceled name it does not predefine and stores it as a
                // canceled string, so we do the same.
                .canceled => if (bool_idx != null) {} else if (num_idx) |i| {
                    self.numbers[i] = canceled;
                } else if (str_idx) |i| {
                    self.strings[i] = .canceled;
                } else try ext_strings.append(arena, .{
                    .name = cap.name,
                    .value = .{ .string = .canceled },
                }),

                .boolean => if (bool_idx) |i| {
                    self.booleans[i] = true;
                } else if (num_idx != null or str_idx != null) {
                    return error.TypeMismatch;
                } else try ext_booleans.append(arena, .{
                    .name = cap.name,
                    .value = .boolean,
                }),

                .numeric => |v| {
                    const n = std.math.cast(i32, v) orelse return error.NumberTooLarge;
                    if (num_idx) |i| {
                        self.numbers[i] = n;
                    } else if (bool_idx != null or str_idx != null) {
                        return error.TypeMismatch;
                    } else try ext_numbers.append(arena, .{
                        .name = cap.name,
                        .value = .{ .numeric = n },
                    });
                },

                .string => |v| {
                    const s: String = .{ .value = try translate(arena, v) };
                    if (str_idx) |i| {
                        self.strings[i] = s;
                    } else if (bool_idx != null or num_idx != null) {
                        return error.TypeMismatch;
                    } else try ext_strings.append(arena, .{
                        .name = cap.name,
                        .value = .{ .string = s },
                    });
                },
            }
        }

        std.mem.sort(Extended, ext_booleans.items, {}, Extended.lessThan);
        std.mem.sort(Extended, ext_numbers.items, {}, Extended.lessThan);
        std.mem.sort(Extended, ext_strings.items, {}, Extended.lessThan);
        self.ext_booleans = ext_booleans.items;
        self.ext_numbers = ext_numbers.items;
        self.ext_strings = ext_strings.items;
        return self;
    }

    fn write(self: *const Entry, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // tic writes each predefined section only up to its last present value.
        var bool_count: usize = 0;
        for (self.booleans, 1..) |v, i| {
            if (v) bool_count = i;
        }
        var num_count: usize = 0;
        for (self.numbers, 1..) |v, i| {
            if (v != absent) num_count = i;
        }
        var str_count: usize = 0;
        for (self.strings, 1..) |v, i| {
            if (v != .absent) str_count = i;
        }

        // tic decides the number width from the predefined numbers alone;
        // checking the extended ones too keeps a large one from being truncated.
        var wide = false;
        for (self.numbers[0..num_count]) |v| {
            if (v > std.math.maxInt(i16)) wide = true;
        }
        for (self.ext_numbers) |ext| {
            if (ext.value.numeric > std.math.maxInt(i16)) wide = true;
        }

        // Header
        try writeShort(w, if (wide) magic_32bit else magic_legacy);
        try writeShort(w, self.names.len + 1);
        try writeShort(w, bool_count);
        try writeShort(w, num_count);
        try writeShort(w, str_count);
        try writeShort(w, tableSize(self.strings[0..str_count]));

        // Names, then booleans, then a pad byte so the numbers start on an
        // even offset.
        try w.writeAll(self.names);
        try w.writeByte(0);
        for (self.booleans[0..bool_count]) |v| try w.writeByte(@intFromBool(v));
        if ((self.names.len + 1 + bool_count) % 2 != 0) try w.writeByte(0);

        for (self.numbers[0..num_count]) |v| try writeNumber(w, v, wide);
        try writeOffsets(w, self.strings[0..str_count]);
        try writeTable(w, self.strings[0..str_count]);

        const ext_count = self.ext_booleans.len + self.ext_numbers.len + self.ext_strings.len;
        if (ext_count == 0) return;

        // ncurses' extended section follows, again on an even offset.
        if (tableSize(self.strings[0..str_count]) % 2 != 0) try w.writeByte(0);

        // Its string table holds the string values, then every extended name
        // (booleans, numbers, strings). Name offsets restart at zero after
        // the values.
        var values: usize = 0;
        var values_size: usize = 0;
        var names_size: usize = 0;
        for (self.ext_strings) |ext| switch (ext.value.string) {
            .value => |v| {
                values += 1;
                values_size += v.len + 1;
            },
            else => {},
        };
        for ([_][]const Extended{ self.ext_booleans, self.ext_numbers, self.ext_strings }) |list| {
            for (list) |ext| names_size += ext.name.len + 1;
        }

        try writeShort(w, self.ext_booleans.len);
        try writeShort(w, self.ext_numbers.len);
        try writeShort(w, self.ext_strings.len);
        try writeShort(w, ext_count + values);
        try writeShort(w, values_size + names_size);

        for (self.ext_booleans) |_| try w.writeByte(1);
        if (self.ext_booleans.len % 2 != 0) try w.writeByte(0);
        for (self.ext_numbers) |ext| try writeNumber(w, ext.value.numeric, wide);

        var offset: usize = 0;
        for (self.ext_strings) |ext| switch (ext.value.string) {
            .absent => try writeShort(w, absent),
            .canceled => try writeShort(w, canceled),
            .value => |v| {
                try writeShort(w, offset);
                offset += v.len + 1;
            },
        };
        offset = 0;
        for ([_][]const Extended{ self.ext_booleans, self.ext_numbers, self.ext_strings }) |list| {
            for (list) |ext| {
                try writeShort(w, offset);
                offset += ext.name.len + 1;
            }
        }

        for (self.ext_strings) |ext| switch (ext.value.string) {
            .value => |v| {
                try w.writeAll(v);
                try w.writeByte(0);
            },
            else => {},
        };
        for ([_][]const Extended{ self.ext_booleans, self.ext_numbers, self.ext_strings }) |list| {
            for (list) |ext| {
                try w.writeAll(ext.name);
                try w.writeByte(0);
            }
        }
    }

    fn tableSize(strings: []const String) usize {
        var size: usize = 0;
        for (strings) |s| switch (s) {
            .value => |v| size += v.len + 1,
            else => {},
        };
        return size;
    }

    fn writeOffsets(w: *std.Io.Writer, strings: []const String) !void {
        var offset: usize = 0;
        for (strings) |s| switch (s) {
            .absent => try writeShort(w, absent),
            .canceled => try writeShort(w, canceled),
            .value => |v| {
                try writeShort(w, offset);
                offset += v.len + 1;
            },
        };
    }

    fn writeTable(w: *std.Io.Writer, strings: []const String) !void {
        for (strings) |s| switch (s) {
            .value => |v| {
                try w.writeAll(v);
                try w.writeByte(0);
            },
            else => {},
        };
    }
};

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// Write a 16-bit little-endian value. Sizes and offsets are known to fit:
/// encode rejects entries larger than max_entry_size.
fn writeShort(w: *std.Io.Writer, value: anytype) !void {
    const v: i16 = @truncate(@as(i32, @intCast(value)));
    try w.writeInt(i16, v, .little);
}

fn writeNumber(w: *std.Io.Writer, value: i32, wide: bool) !void {
    if (wide) {
        try w.writeInt(i32, value, .little);
    } else {
        try w.writeInt(i16, @truncate(value), .little);
    }
}

/// Translate a string value from terminfo source syntax to the bytes tic
/// stores, as ncurses' _nc_trans_string does for terminfo sources. `\E` and
/// `\e` are ESC, `^X` is a control character, `\ddd` is octal, and so on.
/// The stored value is NUL-terminated, so `\0`, `\000` and `^@` become 0200.
fn translate(alloc: Allocator, src: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(alloc, src.len);
    var i: usize = 0;

    // `%^` is the XOR operator of a parameterized string, not a control
    // character.
    var after_percent = false;
    while (i < src.len) {
        const c = src[i];
        i += 1;
        switch (c) {
            0, '\n' => return error.InvalidString,

            '^' => if (!after_percent) {
                if (i >= src.len) return error.InvalidString;
                const ctrl = src[i];
                i += 1;
                out.appendAssumeCapacity(switch (ctrl) {
                    '?' => 0x7f,
                    else => if (ctrl & 0o37 == 0) 0o200 else ctrl & 0o37,
                });
                after_percent = false;
                continue;
            },

            '\\' => {
                if (i >= src.len) return error.InvalidString;
                const e = src[i];
                i += 1;
                if (e >= '0' and e <= '7') {
                    // Up to three digits. tic warns about an 8 or 9 after the
                    // first digit but still reads it as a digit.
                    var n: u32 = e - '0';
                    var digits: usize = 1;
                    while (digits < 3 and i < src.len and std.ascii.isDigit(src[i])) : (digits += 1) {
                        n = n * 8 + (src[i] - '0');
                        i += 1;
                    }
                    const byte: u8 = @truncate(n);
                    out.appendAssumeCapacity(if (byte == 0) 0o200 else byte);
                    after_percent = false;
                } else {
                    out.appendAssumeCapacity(switch (e) {
                        'E', 'e' => 0x1b,
                        'n', 'l' => '\n',
                        'r' => '\r',
                        'b' => 0x08,
                        'f' => 0x0c,
                        't' => '\t',
                        'a' => 0x07,
                        's' => ' ',
                        // `\\`, `\^`, `\,` and `\:` stand for the character,
                        // and tic keeps any other escaped character as-is.
                        else => e,
                    });
                    after_percent = e == '%';
                }
                continue;
            },

            else => {},
        }

        out.appendAssumeCapacity(c);
        after_percent = c == '%';
    }

    return out.items;
}

test "translate" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("\x1b[4:%p1%dm", try translate(alloc, "\\E[4:%p1%dm"));
    try testing.expectEqualStrings("\x07\x7f\x08\x80\x1b", try translate(alloc, "^G^?^H^@^["));
    try testing.expectEqualStrings("%p1%p2%^", try translate(alloc, "%p1%p2%^"));
    try testing.expectEqualStrings("\x80: \n:,\\\x1b\x07\x08\x0c^", try translate(alloc, "\\0\\072\\s\\l\\:\\,\\\\\\e\\a\\b\\f\\^"));
    try testing.expectEqualStrings("S\x10\x80\xff", try translate(alloc, "\\123\\18\\000\\777"));
    try testing.expectEqualStrings("%^G", try translate(alloc, "\\%^G"));

    try testing.expectError(error.InvalidString, translate(alloc, "abc^"));
    try testing.expectError(error.InvalidString, translate(alloc, "abc\\"));
    try testing.expectError(error.InvalidString, translate(alloc, "a\nb"));
    try testing.expectError(error.InvalidString, translate(alloc, "a\x00b"));
}

test "predefined capability tables" {
    const testing = std.testing;

    // The sizes ncurses' term.h names BOOLCOUNT, NUMCOUNT and STRCOUNT.
    try testing.expectEqual(44, caps.booleans.len);
    try testing.expectEqual(39, caps.numbers.len);
    try testing.expectEqual(414, caps.strings.len);

    // A few indices from term.h, one per region of each table.
    try testing.expectEqual(1, indexOf(&caps.booleans, "am"));
    try testing.expectEqual(28, indexOf(&caps.booleans, "bce"));
    try testing.expectEqual(37, indexOf(&caps.booleans, "OTbs"));
    try testing.expectEqual(13, indexOf(&caps.numbers, "colors"));
    try testing.expectEqual(33, indexOf(&caps.numbers, "OTug"));
    try testing.expectEqual(55, indexOf(&caps.strings, "kbs"));
    try testing.expectEqual(359, indexOf(&caps.strings, "setaf"));
    try testing.expectEqual(394, indexOf(&caps.strings, "OTi2"));
    try testing.expectEqual(413, indexOf(&caps.strings, "box1"));
}

test "encode matches tic" {
    // testdata/fixture-term was compiled by `tic -x` (ncurses 6.6.20251230)
    // from this source:
    //
    //   fixture-term|fixture|Fixture Terminal,
    //       am, xenl@, OTbs, AX, Zz@,
    //       colors#256, cols@, OTug#3, Xn#7,
    //       bel=^G, cr=\r, kbs=^?, cub1=^@, ht=\t, ind=\n,
    //       is2=\0\072\s\l\:\,\\\e\a\b\f\^^[, flash=\123\18%^, el@,
    //       Smulx=\E[4:%p1%dm, kDN@, Ss=\E[%p1%d q,
    //
    // It covers canceled predefined and extended capabilities, a boolean
    // past the SVr4 ones, every string escape, and padding after an odd
    // string table.
    const src: Source = .{
        .names = &.{ "fixture-term", "fixture", "Fixture Terminal" },
        .capabilities = &.{
            .{ .name = "am", .value = .{ .boolean = {} } },
            .{ .name = "xenl", .value = .{ .canceled = {} } },
            .{ .name = "OTbs", .value = .{ .boolean = {} } },
            .{ .name = "AX", .value = .{ .boolean = {} } },
            .{ .name = "Zz", .value = .{ .canceled = {} } },
            .{ .name = "colors", .value = .{ .numeric = 256 } },
            .{ .name = "cols", .value = .{ .canceled = {} } },
            .{ .name = "OTug", .value = .{ .numeric = 3 } },
            .{ .name = "Xn", .value = .{ .numeric = 7 } },
            .{ .name = "bel", .value = .{ .string = "^G" } },
            .{ .name = "cr", .value = .{ .string = "\\r" } },
            .{ .name = "kbs", .value = .{ .string = "^?" } },
            .{ .name = "cub1", .value = .{ .string = "^@" } },
            .{ .name = "ht", .value = .{ .string = "\\t" } },
            .{ .name = "ind", .value = .{ .string = "\\n" } },
            .{ .name = "is2", .value = .{ .string = "\\0\\072\\s\\l\\:\\,\\\\\\e\\a\\b\\f\\^^[" } },
            .{ .name = "flash", .value = .{ .string = "\\123\\18%^" } },
            .{ .name = "el", .value = .{ .canceled = {} } },
            .{ .name = "Smulx", .value = .{ .string = "\\E[4:%p1%dm" } },
            .{ .name = "kDN", .value = .{ .canceled = {} } },
            .{ .name = "Ss", .value = .{ .string = "\\E[%p1%d q" } },
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(std.testing.allocator, src, &out.writer);
    try std.testing.expectEqualSlices(u8, @embedFile("testdata/fixture-term"), out.written());
}

test "encode matches tic with 32-bit numbers" {
    // testdata/wide-term was compiled by `tic -x` (ncurses 6.6.20251230) from:
    //
    //   wide-term|Wide Numbers,
    //       bw, am, Tc,
    //       colors#0x1000000, pairs#0x10000, U8#1,
    //       kbs=^H, setrgbf=\E[38:2:%p1%d:%p2%d:%p3%dm,
    //
    // A predefined number above 32767 makes tic write 32-bit numbers, the
    // extended ones included.
    const src: Source = .{
        .names = &.{ "wide-term", "Wide Numbers" },
        .capabilities = &.{
            .{ .name = "bw", .value = .{ .boolean = {} } },
            .{ .name = "am", .value = .{ .boolean = {} } },
            .{ .name = "Tc", .value = .{ .boolean = {} } },
            .{ .name = "colors", .value = .{ .numeric = 0x1000000 } },
            .{ .name = "pairs", .value = .{ .numeric = 0x10000 } },
            .{ .name = "U8", .value = .{ .numeric = 1 } },
            .{ .name = "kbs", .value = .{ .string = "^H" } },
            .{ .name = "setrgbf", .value = .{ .string = "\\E[38:2:%p1%d:%p2%d:%p3%dm" } },
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(std.testing.allocator, src, &out.writer);
    try std.testing.expectEqualSlices(u8, @embedFile("testdata/wide-term"), out.written());
}

test "encode matches tic for a canceled boolean after the last true one" {
    // testdata/canceled-term was compiled by `tic -x` (ncurses 6.6.20251230)
    // from:
    //
    //   canceled-term|Canceled Boolean,
    //       am, km@,
    //       colors#8,
    //
    // tic writes booleans only up to the last true one, so the canceled km
    // (index 8) leaves the section 2 bytes long, after am (index 1).
    const src: Source = .{
        .names = &.{ "canceled-term", "Canceled Boolean" },
        .capabilities = &.{
            .{ .name = "am", .value = .{ .boolean = {} } },
            .{ .name = "km", .value = .{ .canceled = {} } },
            .{ .name = "colors", .value = .{ .numeric = 8 } },
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(std.testing.allocator, src, &out.writer);
    try std.testing.expectEqualSlices(u8, @embedFile("testdata/canceled-term"), out.written());
}

test "isEntry" {
    const testing = std.testing;
    for ([_][]const u8{
        @embedFile("testdata/fixture-term"),
        @embedFile("testdata/wide-term"),
        @embedFile("testdata/canceled-term"),
    }) |entry| {
        try testing.expect(isEntry(entry));

        // Cut inside the string table, before the extended section.
        try testing.expect(!isEntry(entry[0..header_size]));
        try testing.expect(!isEntry(entry[0 .. entry.len / 3]));
    }
    try testing.expect(!isEntry(""));
    try testing.expect(!isEntry("not a terminfo entry at all"));
}

test "encode rejects what tic would resolve or reject differently" {
    const testing = std.testing;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try testing.expectError(error.DuplicateCapability, encode(testing.allocator, .{
        .names = &.{"t"},
        .capabilities = &.{
            .{ .name = "am", .value = .{ .boolean = {} } },
            .{ .name = "am", .value = .{ .boolean = {} } },
        },
    }, &out.writer));
    try testing.expectError(error.TypeMismatch, encode(testing.allocator, .{
        .names = &.{"t"},
        .capabilities = &.{.{ .name = "colors", .value = .{ .string = "256" } }},
    }, &out.writer));
    try testing.expectError(error.UnsupportedUse, encode(testing.allocator, .{
        .names = &.{"t"},
        .capabilities = &.{.{ .name = "use", .value = .{ .string = "xterm" } }},
    }, &out.writer));
    try testing.expectError(error.NumberTooLarge, encode(testing.allocator, .{
        .names = &.{"t"},
        .capabilities = &.{.{ .name = "colors", .value = .{ .numeric = 0x80000000 } }},
    }, &out.writer));
}

test "writeDatabase" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const src: Source = .{
        .names = &.{ "xterm-test", "test", "Test Terminal" },
        .capabilities = &.{.{ .name = "am", .value = .{ .boolean = {} } }},
    };
    try writeDatabase(testing.allocator, src, tmp.dir);

    var expected: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    try encode(testing.allocator, src, &expected.writer);

    for ([_][]const u8{ "78/xterm-test", "74/test" }) |path| {
        const data = try tmp.dir.readFileAlloc(testing.allocator, path, max_entry_size);
        defer testing.allocator.free(data);
        try testing.expectEqualSlices(u8, expected.written(), data);
    }

    // The description gets no file.
    try testing.expectError(error.FileNotFound, tmp.dir.access("54/Test Terminal", .{}));
}

test "names that cannot be encoded or written" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(error.InvalidName, writeDatabase(testing.allocator, .{
        .names = &.{ "bad/name", "Bad" },
        .capabilities = &.{},
    }, tmp.dir));
    try testing.expectError(error.InvalidName, writeDatabase(testing.allocator, .{
        .names = &.{ "bad|name", "Bad" },
        .capabilities = &.{},
    }, tmp.dir));
    try testing.expectError(error.InvalidName, writeDatabase(testing.allocator, .{
        .names = &.{},
        .capabilities = &.{},
    }, tmp.dir));
}
