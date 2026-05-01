const std = @import("std");
const Allocator = std.mem.Allocator;
const actionpkg = @import("action.zig");
const args = @import("args.zig");
const ghostty_terminfo = @import("../terminfo/ghostty.zig").ghostty;

pub const Category = enum {
    terminfo,
    osc,
    csi,
};

pub const Direction = enum {
    advertise,
    parse,
    parse_emit,
};

pub const Capability = struct {
    id: []const u8,
    category: Category,
    direction: Direction,
};

pub const Report = struct {
    source: []const u8,
    term: []const u8,
    capabilities: []const Capability,
};

const default_term = ghostty_terminfo.names[0];
const terminfo_capability_id = "terminfo-" ++ default_term;
const capabilities = [_]Capability{
    .{
        .id = terminfo_capability_id,
        .category = .terminfo,
        .direction = .advertise,
    },
    .{
        .id = "osc-8-hyperlink",
        .category = .osc,
        .direction = .parse_emit,
    },
    .{
        .id = "osc-4-palette",
        .category = .osc,
        .direction = .parse_emit,
    },
    .{
        .id = "osc-10-11-colors",
        .category = .osc,
        .direction = .parse_emit,
    },
    .{
        .id = "osc-21-kitty-color-stack",
        .category = .osc,
        .direction = .parse,
    },
    .{
        .id = "csi-2026-synchronized-output",
        .category = .csi,
        .direction = .parse,
    },
};

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return actionpkg.help_error;
    }
};

/// The `vt-probe` command prints a deterministic VT capability summary for
/// developer diagnostics.
///
/// This is a static probe of compiled winghostty support. It does not query a
/// live terminal, start the GUI, or depend on ConPTY runtime state.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    try writePlain(&stdout_writer.interface, report());
    try stdout_writer.interface.flush();

    return 0;
}

pub fn report() Report {
    return .{
        .source = "static",
        .term = default_term,
        .capabilities = &capabilities,
    };
}

pub fn writePlain(writer: *std.Io.Writer, probe: Report) std.Io.Writer.Error!void {
    try writer.print(
        "probe={s}\nterm={s}\n",
        .{ probe.source, probe.term },
    );

    for (probe.capabilities) |capability| {
        try writer.print(
            "capability={s} category={s} direction={s}\n",
            .{
                capability.id,
                categoryString(capability.category),
                directionString(capability.direction),
            },
        );
    }
}

fn categoryString(value: Category) []const u8 {
    return switch (value) {
        .terminfo => "terminfo",
        .osc => "osc",
        .csi => "csi",
    };
}

fn directionString(value: Direction) []const u8 {
    return switch (value) {
        .advertise => "advertise",
        .parse => "parse",
        .parse_emit => "parse+emit",
    };
}

test "vt-probe report includes core capabilities" {
    const testing = std.testing;
    const probe = report();

    try testing.expectEqualStrings("static", probe.source);
    try testing.expectEqualStrings(default_term, probe.term);
    try testing.expectEqual(@as(usize, 6), probe.capabilities.len);

    try testing.expectEqualStrings(terminfo_capability_id, probe.capabilities[0].id);
    try testing.expectEqualStrings("osc-8-hyperlink", probe.capabilities[1].id);
    try testing.expectEqualStrings("osc-4-palette", probe.capabilities[2].id);
    try testing.expectEqualStrings("osc-10-11-colors", probe.capabilities[3].id);
    try testing.expectEqualStrings("osc-21-kitty-color-stack", probe.capabilities[4].id);
    try testing.expectEqualStrings("csi-2026-synchronized-output", probe.capabilities[5].id);
}

test "vt-probe terminfo claim tracks compiled terminfo" {
    const testing = std.testing;
    const probe = report();

    try testing.expectEqualStrings(ghostty_terminfo.names[0], probe.term);
    try testing.expectEqualStrings(terminfo_capability_id, probe.capabilities[0].id);
}

test "vt-probe plain output is deterministic" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePlain(&writer, report());

    try testing.expectEqualStrings(
        \\probe=static
        \\term=xterm-ghostty
        \\capability=terminfo-xterm-ghostty category=terminfo direction=advertise
        \\capability=osc-8-hyperlink category=osc direction=parse+emit
        \\capability=osc-4-palette category=osc direction=parse+emit
        \\capability=osc-10-11-colors category=osc direction=parse+emit
        \\capability=osc-21-kitty-color-stack category=osc direction=parse
        \\capability=csi-2026-synchronized-output category=csi direction=parse
        \\
    ,
        writer.buffered(),
    );
}
