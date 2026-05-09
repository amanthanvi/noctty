const std = @import("std");
const Allocator = std.mem.Allocator;
const actionpkg = @import("action.zig");
const args = @import("args.zig");
const ghostty_terminfo = @import("../terminfo/ghostty.zig").ghostty;

pub const category = enum {
    terminfo,
    osc,
    csi,
};

pub const direction = enum {
    advertise,
    parse,
    parse_emit,
};

pub const capability = struct {
    id: []const u8,
    category: category,
    direction: direction,
};

pub const report = struct {
    source: []const u8,
    term: []const u8,
    capabilities: []const capability,
};

const defaultTerm = ghostty_terminfo.names[0];
const terminfoCapabilityId = "terminfo-" ++ defaultTerm;
const capabilities = [_]capability{
    .{
        .id = terminfoCapabilityId,
        .category = .terminfo,
        .direction = .advertise,
    },
    .{
        .id = "osc-7-working-directory",
        .category = .osc,
        .direction = .parse,
    },
    .{
        .id = "osc-8-hyperlink",
        .category = .osc,
        .direction = .parse_emit,
    },
    .{
        .id = "osc-9-desktop-notification",
        .category = .osc,
        .direction = .parse,
    },
    .{
        .id = "osc-777-desktop-notification",
        .category = .osc,
        .direction = .parse,
    },
    .{
        .id = "osc-9-4-progress",
        .category = .osc,
        .direction = .parse,
    },
    .{
        .id = "osc-52-clipboard",
        .category = .osc,
        .direction = .parse_emit,
    },
    .{
        .id = "osc-133-semantic-prompt",
        .category = .osc,
        .direction = .parse,
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

pub const options = struct {
    pub fn deinit(self: options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: options) !void {
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
    var opts: options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(options, alloc, &opts, &iter);
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    try writePlain(&stdout_writer.interface, probeReport());
    try stdout_writer.interface.flush();

    return 0;
}

pub fn probeReport() report {
    return .{
        .source = "static",
        .term = defaultTerm,
        .capabilities = &capabilities,
    };
}

pub fn writePlain(writer: *std.Io.Writer, probe: report) std.Io.Writer.Error!void {
    try writer.print(
        "probe={s}\nterm={s}\n",
        .{ probe.source, probe.term },
    );

    for (probe.capabilities) |entry| {
        try writer.print(
            "capability={s} category={s} direction={s}\n",
            .{
                entry.id,
                categoryString(entry.category),
                directionString(entry.direction),
            },
        );
    }
}

fn categoryString(value: category) []const u8 {
    return switch (value) {
        .terminfo => "terminfo",
        .osc => "osc",
        .csi => "csi",
    };
}

fn directionString(value: direction) []const u8 {
    return switch (value) {
        .advertise => "advertise",
        .parse => "parse",
        .parse_emit => "parse+emit",
    };
}

test "vt-probe report includes core capabilities" {
    const testing = std.testing;
    const probe = probeReport();

    try testing.expectEqualStrings("static", probe.source);
    try testing.expectEqualStrings(defaultTerm, probe.term);
    try testing.expectEqual(@as(usize, 12), probe.capabilities.len);

    try testing.expectEqualStrings(terminfoCapabilityId, probe.capabilities[0].id);
    try testing.expectEqualStrings("osc-7-working-directory", probe.capabilities[1].id);
    try testing.expectEqualStrings("osc-8-hyperlink", probe.capabilities[2].id);
    try testing.expectEqualStrings("osc-9-desktop-notification", probe.capabilities[3].id);
    try testing.expectEqualStrings("osc-777-desktop-notification", probe.capabilities[4].id);
    try testing.expectEqualStrings("osc-9-4-progress", probe.capabilities[5].id);
    try testing.expectEqualStrings("osc-52-clipboard", probe.capabilities[6].id);
    try testing.expectEqualStrings("osc-133-semantic-prompt", probe.capabilities[7].id);
    try testing.expectEqualStrings("osc-4-palette", probe.capabilities[8].id);
    try testing.expectEqualStrings("osc-10-11-colors", probe.capabilities[9].id);
    try testing.expectEqualStrings("osc-21-kitty-color-stack", probe.capabilities[10].id);
    try testing.expectEqualStrings("csi-2026-synchronized-output", probe.capabilities[11].id);
}

test "vt-probe terminfo claim tracks compiled terminfo" {
    const testing = std.testing;
    const probe = probeReport();

    try testing.expectEqualStrings(ghostty_terminfo.names[0], probe.term);
    try testing.expectEqualStrings(terminfoCapabilityId, probe.capabilities[0].id);
}

test "vt-probe plain output is deterministic" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writePlain(&writer, probeReport());

    try testing.expectEqualStrings(
        \\probe=static
        \\term=xterm-ghostty
        \\capability=terminfo-xterm-ghostty category=terminfo direction=advertise
        \\capability=osc-7-working-directory category=osc direction=parse
        \\capability=osc-8-hyperlink category=osc direction=parse+emit
        \\capability=osc-9-desktop-notification category=osc direction=parse
        \\capability=osc-777-desktop-notification category=osc direction=parse
        \\capability=osc-9-4-progress category=osc direction=parse
        \\capability=osc-52-clipboard category=osc direction=parse+emit
        \\capability=osc-133-semantic-prompt category=osc direction=parse
        \\capability=osc-4-palette category=osc direction=parse+emit
        \\capability=osc-10-11-colors category=osc direction=parse+emit
        \\capability=osc-21-kitty-color-stack category=osc direction=parse
        \\capability=csi-2026-synchronized-output category=csi direction=parse
        \\
    ,
        writer.buffered(),
    );
}
