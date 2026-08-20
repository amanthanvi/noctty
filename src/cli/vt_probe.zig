const std = @import("std");
const Allocator = std.mem.Allocator;
const actionpkg = @import("action.zig");
const args = @import("args.zig");
const ghostty_terminfo = @import("../terminfo/ghostty.zig").ghostty;

pub const category = enum {
    terminfo,
    osc,
    csi,
    graphics,
};

pub const direction = enum {
    advertise,
    parse,
    parse_emit,
};

pub const win32_runtime = enum {
    not_applicable,
    parser_only,
    validated,
    pending,
};

pub const capability = struct {
    id: []const u8,
    category: category,
    direction: direction,
    win32_runtime: win32_runtime,
    evidence: []const u8,
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
        .win32_runtime = .not_applicable,
        .evidence = "terminfo-advertisement",
    },
    .{
        .id = "osc-7-working-directory",
        .category = .osc,
        .direction = .parse,
        .win32_runtime = .parser_only,
        .evidence = "powershell-shell-integration emits OSC 7; no Win32 GUI state harness",
    },
    .{
        .id = "osc-8-hyperlink",
        .category = .osc,
        .direction = .parse_emit,
        .win32_runtime = .pending,
        .evidence = "link storage/formatter covered by core tests; no Win32 click/tooltip harness",
    },
    .{
        .id = "osc-9-desktop-notification",
        .category = .osc,
        .direction = .parse,
        .win32_runtime = .validated,
        .evidence = "test/windows/interactive-win11-command-finish.ps1",
    },
    .{
        .id = "osc-777-desktop-notification",
        .category = .osc,
        .direction = .parse,
        .win32_runtime = .parser_only,
        .evidence = "shared notification parser path; no dedicated Win32 OSC 777 payload harness",
    },
    .{
        .id = "osc-9-4-progress",
        .category = .osc,
        .direction = .parse,
        .win32_runtime = .validated,
        .evidence = "test/windows/interactive-win11-progress.ps1",
    },
    .{
        .id = "osc-52-clipboard",
        .category = .osc,
        .direction = .parse_emit,
        .win32_runtime = .pending,
        .evidence = "Win32 clipboard policy exists; no non-interactive OSC 52 prompt/read/write harness",
    },
    .{
        .id = "osc-133-semantic-prompt",
        .category = .osc,
        .direction = .parse,
        .win32_runtime = .validated,
        .evidence = "test/windows/interactive-win11-command-finish.ps1",
    },
    .{
        .id = "osc-4-palette",
        .category = .osc,
        .direction = .parse_emit,
        .win32_runtime = .parser_only,
        .evidence = "core color protocol tests; no Win32 rendered palette harness",
    },
    .{
        .id = "osc-10-11-colors",
        .category = .osc,
        .direction = .parse_emit,
        .win32_runtime = .parser_only,
        .evidence = "core color protocol tests; no Win32 rendered default-color harness",
    },
    .{
        .id = "osc-21-kitty-color-stack",
        .category = .osc,
        .direction = .parse,
        .win32_runtime = .parser_only,
        .evidence = "core kitty color protocol tests; no Win32 rendered color-stack harness",
    },
    .{
        .id = "csi-2026-synchronized-output",
        .category = .csi,
        .direction = .parse,
        .win32_runtime = .validated,
        .evidence = "test/windows/interactive-win11-boo-performance.ps1",
    },
    .{
        .id = "kitty-graphics",
        .category = .graphics,
        .direction = .parse,
        .win32_runtime = .pending,
        .evidence = "core Kitty graphics tests; no Win32 pixel/renderer harness",
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
/// This is a static probe of compiled noctty support. It does not query a
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
            "capability={s} category={s} direction={s} win32-runtime={s} evidence=",
            .{
                entry.id,
                categoryString(entry.category),
                directionString(entry.direction),
                win32RuntimeString(entry.win32_runtime),
            },
        );
        try writeQuoted(writer, entry.evidence);
        try writer.writeByte('\n');
    }
}

fn writeQuoted(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\', '"' => try writer.print("\\{c}", .{byte}),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn categoryString(value: category) []const u8 {
    return switch (value) {
        .terminfo => "terminfo",
        .osc => "osc",
        .csi => "csi",
        .graphics => "graphics",
    };
}

fn directionString(value: direction) []const u8 {
    return switch (value) {
        .advertise => "advertise",
        .parse => "parse",
        .parse_emit => "parse+emit",
    };
}

fn win32RuntimeString(value: win32_runtime) []const u8 {
    return switch (value) {
        .not_applicable => "not-applicable",
        .parser_only => "parser-only",
        .validated => "validated",
        .pending => "pending",
    };
}

test "vt-probe report includes core capabilities" {
    const testing = std.testing;
    const probe = probeReport();

    try testing.expectEqualStrings("static", probe.source);
    try testing.expectEqualStrings(defaultTerm, probe.term);
    try testing.expectEqual(@as(usize, 13), probe.capabilities.len);

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
    try testing.expectEqualStrings("kitty-graphics", probe.capabilities[12].id);
    try testing.expectEqual(win32_runtime.validated, probe.capabilities[3].win32_runtime);
    try testing.expectEqual(win32_runtime.validated, probe.capabilities[5].win32_runtime);
    try testing.expectEqual(win32_runtime.validated, probe.capabilities[7].win32_runtime);
    try testing.expectEqual(win32_runtime.validated, probe.capabilities[11].win32_runtime);
    try testing.expectEqual(win32_runtime.pending, probe.capabilities[12].win32_runtime);
}

test "vt-probe terminfo claim tracks compiled terminfo" {
    const testing = std.testing;
    const probe = probeReport();

    try testing.expectEqualStrings(ghostty_terminfo.names[0], probe.term);
    try testing.expectEqualStrings(terminfoCapabilityId, probe.capabilities[0].id);
}

test "vt-probe plain output is deterministic" {
    const testing = std.testing;
    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();
    try writePlain(&writer.writer, probeReport());

    try testing.expectEqualStrings(
        \\probe=static
        \\term=xterm-ghostty
        \\capability=terminfo-xterm-ghostty category=terminfo direction=advertise win32-runtime=not-applicable evidence="terminfo-advertisement"
        \\capability=osc-7-working-directory category=osc direction=parse win32-runtime=parser-only evidence="powershell-shell-integration emits OSC 7; no Win32 GUI state harness"
        \\capability=osc-8-hyperlink category=osc direction=parse+emit win32-runtime=pending evidence="link storage/formatter covered by core tests; no Win32 click/tooltip harness"
        \\capability=osc-9-desktop-notification category=osc direction=parse win32-runtime=validated evidence="test/windows/interactive-win11-command-finish.ps1"
        \\capability=osc-777-desktop-notification category=osc direction=parse win32-runtime=parser-only evidence="shared notification parser path; no dedicated Win32 OSC 777 payload harness"
        \\capability=osc-9-4-progress category=osc direction=parse win32-runtime=validated evidence="test/windows/interactive-win11-progress.ps1"
        \\capability=osc-52-clipboard category=osc direction=parse+emit win32-runtime=pending evidence="Win32 clipboard policy exists; no non-interactive OSC 52 prompt/read/write harness"
        \\capability=osc-133-semantic-prompt category=osc direction=parse win32-runtime=validated evidence="test/windows/interactive-win11-command-finish.ps1"
        \\capability=osc-4-palette category=osc direction=parse+emit win32-runtime=parser-only evidence="core color protocol tests; no Win32 rendered palette harness"
        \\capability=osc-10-11-colors category=osc direction=parse+emit win32-runtime=parser-only evidence="core color protocol tests; no Win32 rendered default-color harness"
        \\capability=osc-21-kitty-color-stack category=osc direction=parse win32-runtime=parser-only evidence="core kitty color protocol tests; no Win32 rendered color-stack harness"
        \\capability=csi-2026-synchronized-output category=csi direction=parse win32-runtime=validated evidence="test/windows/interactive-win11-boo-performance.ps1"
        \\capability=kitty-graphics category=graphics direction=parse win32-runtime=pending evidence="core Kitty graphics tests; no Win32 pixel/renderer harness"
        \\
    ,
        writer.written(),
    );
}
