const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const args = @import("args.zig");
const font = @import("../font/main.zig");

const log = std.log.scoped(.list_fonts);

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// The font family to search for. If this is set, then only fonts
    /// matching this family will be listed.
    family: ?[:0]const u8 = null,

    /// The style name to search for.
    style: ?[:0]const u8 = null,

    /// Font styles to search for. If this is set, then only fonts that
    /// match the given styles will be listed.
    bold: bool = false,
    italic: bool = false,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return actionpkg.help_error;
    }
};

/// The `list-fonts` command is used to list all the available fonts for
/// noctty. This uses the exact same font discovery mechanism noctty uses to
/// find fonts to use.
///
/// When executed with no arguments, this will list all available fonts, sorted
/// by family name, then font name. If a family name is given with `--family`,
/// the sorting will be disabled and the results instead will be shown in the
/// same priority order Ghostty would use to pick a font.
///
/// A family whose typographic name (OpenType name ID 16) differs from the
/// legacy family name is shown as `Legacy (Typographic)`. Either name works
/// in `font-family`; Nerd Fonts v3 installs advertise only the typographic
/// one (`JetBrainsMono Nerd Font Mono` for the family Windows registers as
/// `JetBrainsMono NFM`).
///
/// Flags:
///
///   * `--bold`: Filter results to specific bold styles. It is not guaranteed
///     that only those styles are returned. They are only prioritized.
///
///   * `--italic`: Filter results to specific italic styles. It is not guaranteed
///     that only those styles are returned. They are only prioritized.
///
///   * `--style`: Filter results based on the style string advertised by a font.
///     It is not guaranteed that only those styles are returned. They are only
///     prioritized.
///
///   * `--family`: Filter results to a specific font family. The family handling
///     is identical to the `font-family` set of noctty configuration values, so
///     this can be used to debug why your desired font may not be loading.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    var config: Options = .{};
    defer config.deinit();
    try args.parse(Options, alloc_gpa, &config, argsIter);

    // Use an arena for all our memory allocs
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Its possible to build Ghostty without font discovery!
    if (comptime font.Discover == void) {
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print(
            \\noctty was built without a font discovery mechanism. This is a compile-time
            \\option. Please review how noctty was built from source, contact the
            \\maintainer to enable a font discovery mechanism, and try again.
        ,
            .{},
        );
        try stderr.flush();
        return 1;
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;

    // We'll be putting our fonts into a list categorized by family
    // so it is easier to read the output.
    var families: std.ArrayList([]const u8) = .empty;
    var map: std.StringHashMap(std.ArrayListUnmanaged([]const u8)) = .init(alloc);

    // Look up all available fonts
    var disco = font.Discover.init();
    defer disco.deinit();
    var disco_it = try disco.discover(alloc, .{
        .family = config.family,
        .style = config.style,
        .bold = config.bold,
        .italic = config.italic,
        .monospace = config.family == null,
    });
    defer disco_it.deinit();
    while (try disco_it.next()) |face| {
        var buf: [1024]u8 = undefined;

        const family_buf = face.familyName(&buf) catch |err| {
            log.err("failed to get font family name: {}", .{err});
            continue;
        };

        // A font whose typographic family (OpenType name ID 16) differs
        // from its legacy family is listed under both names, because both
        // are accepted by `font-family` and installation guides for such
        // fonts (Nerd Fonts v3 in particular) only ever mention the
        // typographic one.
        var typographic_buf: [1024]u8 = undefined;
        const family = family: {
            const typographic = face.typographicFamilyName(&typographic_buf) catch |err| {
                log.err("failed to get typographic family name: {}", .{err});
                break :family try alloc.dupe(u8, family_buf);
            } orelse break :family try alloc.dupe(u8, family_buf);
            if (std.ascii.eqlIgnoreCase(typographic, family_buf)) {
                break :family try alloc.dupe(u8, family_buf);
            }
            break :family try std.fmt.allocPrint(
                alloc,
                "{s} ({s})",
                .{ family_buf, typographic },
            );
        };

        const full_name_buf = face.name(&buf) catch |err| {
            log.err("failed to get font name: {}", .{err});
            continue;
        };
        const full_name = try alloc.dupe(u8, full_name_buf);

        const gop = try map.getOrPut(family);
        if (!gop.found_existing) {
            try families.append(alloc, family);
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(alloc, full_name);
    }

    // Sort our keys.
    if (config.family == null) {
        std.mem.sortUnstable([]const u8, families.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);
    }

    // Output each
    for (families.items) |family| {
        const list = map.get(family) orelse continue;
        if (list.items.len == 0) continue;
        if (config.family == null) {
            std.mem.sortUnstable([]const u8, list.items, {}, struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.lessThan);
        }

        try stdout.print("{s}\n", .{family});
        for (list.items) |item| try stdout.print("  {s}\n", .{item});
        try stdout.print("\n", .{});
    }

    try stdout.flush();
    return 0;
}
