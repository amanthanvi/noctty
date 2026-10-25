const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const args = @import("args.zig");
const configpkg = @import("../config.zig");
const windows_shell = @import("../config/windows_shell.zig");
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.list_profiles);

/// The `schema` member of the JSON output. A change that removes or renames a
/// member bumps the number.
const json_schema = "noctty.profiles.v1";

const Format = enum { text, json };

/// How the profiles are written: an aligned table for a person at a terminal,
/// tab-separated lines for a program, or one JSON document.
const Style = enum { table, plain, json };

pub const Options = struct {
    /// Print one tab-separated line per profile even on a terminal.
    plain: bool = false,

    /// `text` prints the table or the plain lines; `json` prints one JSON
    /// document.
    format: Format = .text,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return actionpkg.help_error;
    }
};

/// The `list-profiles` command prints the profiles the profile picker and the
/// command palette offer, in the order they offer them, with the key to put in
/// `default-profile`, `profile-order` or `profile-hidden`.
///
/// Each profile has four fields:
///
///   * `key`: what the three settings above take, such as `pwsh.exe`,
///     `wsl:Ubuntu`, `ssh:build-01`, `user:py312` (a `profile-command` id) or
///     `vs:<instance id>:cmd`.
///
///   * `label`: the name the picker shows.
///
///   * `source`: `detected` for a shell, WSL distribution or SSH host found
///     on this machine, `config` for a profile defined with
///     `profile-command`, and `visual-studio` for a Visual Studio developer
///     shell.
///
///   * `state`: `shown`, or `hidden` for a profile `profile-hidden` or
///     `visual-studio-profiles = newest` takes out of the lists (the JSON
///     member is `hidden`, true or false). Hidden profiles come after the
///     shown ones and still start when something names them.
///
/// The command never prints a profile's command line, environment variables
/// or working directory.
///
/// It reads the configuration files and searches for shells the way a new
/// noctty does when it starts, with this process's environment and for the
/// light or dark scheme Windows reports for apps (a `theme = light:A,dark:B`
/// can set profile keys). That includes asking `wsl.exe` for its
/// distributions when `wsl.exe` is on `PATH`. A
/// quick slot pinned in a running noctty moves a profile to the front of that
/// instance's picker, and this command, a separate process, does not see the
/// pin. A `profile-command` line the config reader rejects leaves its profile
/// out; `noctty +validate-config` reports it.
///
/// On a terminal the profiles are an aligned table with a header. Anywhere
/// else, or with `--plain`, each profile is one line of tab-separated fields
/// in the order above, without a header. Both are UTF-8; a control character
/// in a label prints as `?`.
///
/// If a search did not finish in time (WSL, the SSH config or Visual Studio),
/// the list may be missing profiles: a note says so on stderr, and the JSON
/// has `"complete": false`. Run the command again.
///
/// Flags:
///
///   * `--plain`: Print tab-separated lines even on a terminal. This is the
///     default when the output is not a terminal.
///
///   * `--format=json`: Print one JSON document, `{"schema":"noctty.profiles.v1",
///     "complete":true,"profiles":[{"key":"...","label":"...","source":"...",
///     "hidden":false}]}`, for scripts. It is ASCII: other characters are
///     `\u` escapes, so a console code page cannot garble it. `--format=text`
///     is the default.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    // Streaming, not positional: stdout may be a pipe or a file opened for
    // append (see validate-config).
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const result = runArgs(
        alloc,
        &iter,
        stdout,
        stderr,
        std.fs.File.stdout().isTty(),
        discoverFromConfig,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

/// Finds the profiles for the configuration the files and the environment
/// give, with the discovery the picker runs. The result lives in `alloc`.
const DiscoverFn = *const fn (alloc: Allocator) anyerror!windows_shell.ProfileDiscovery;

fn discoverFromConfig(alloc: Allocator) !windows_shell.ProfileDiscovery {
    var config = try configpkg.Config.load(alloc);
    defer config.deinit();
    return try discoverForScheme(alloc, &config, internal_os.color_scheme.apps(), windows_shell.discoverProfiles);
}

/// `config` as the app has it: `Config.load` leaves it in the light
/// conditional state, and the app applies the scheme Windows reports before
/// its first window (`App.syncStartupConfig`, then `App.updateConfig`). A
/// `theme = light:A,dark:B` file can set any key, the profile keys among
/// them, so a dark desktop can list other profiles than a light one. As
/// there, a state that cannot be applied leaves `config` as it is.
/// `scheme` is `os.color_scheme.apps()` or a test's.
fn discoverForScheme(
    alloc: Allocator,
    config: *const configpkg.Config,
    scheme: internal_os.color_scheme.Scheme,
    discover: anytype,
) !windows_shell.ProfileDiscovery {
    var applied: ?configpkg.Config = config.changeConditionalState(.{
        .theme = switch (scheme) {
            .light => .light,
            .dark => .dark,
        },
    }) catch |err| failed: {
        if (err == error.OutOfMemory) return err;
        log.warn("could not apply the color scheme to the configuration err={}", .{err});
        break :failed null;
    };
    defer if (applied) |*value| value.deinit();
    return try discoverForConfig(alloc, if (applied) |*value| value else config, discover);
}

/// What the picker does with a loaded configuration: the user profiles, the
/// order, the hidden list and Visual Studio's setting through `UserProfiles`,
/// and the SSH setting beside it. `discover` is `windows_shell.discoverProfiles`
/// or a test's.
fn discoverForConfig(
    alloc: Allocator,
    config: *const configpkg.Config,
    discover: anytype,
) !windows_shell.ProfileDiscovery {
    var user = try windows_shell.UserProfiles.init(alloc, config);
    defer user.deinit();
    return try discover(alloc, config.@"ssh-config-hosts", &user);
}

fn runArgs(
    alloc: Allocator,
    args_iter: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    stdout_is_tty: bool,
    discover: DiscoverFn,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    args.parse(Options, alloc, &opts, args_iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing +list-profiles arguments: {s}\n", .{@errorName(err)});
            return 1;
        },
    };

    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const discovery = try discover(arena.allocator());

    const style: Style = if (opts.format == .json)
        .json
    else if (opts.plain or !stdout_is_tty)
        .plain
    else
        .table;
    try writeProfiles(arena.allocator(), stdout, style, discovery);
    if (!discovery.complete) try stderr.writeAll(incomplete_note);
    return 0;
}

const incomplete_note =
    "The list may be missing profiles: a search for WSL distributions, SSH hosts or " ++
    "Visual Studio did not finish. Run the command again.\n";

/// What the command prints of a profile, and nothing else: a profile's
/// command, variables and directory never reach a writer.
const Entry = struct {
    key: []const u8,
    label: []const u8,
    source: []const u8,
    hidden: bool,

    fn state(self: Entry) []const u8 {
        return if (self.hidden) "hidden" else "shown";
    }
};

fn sourceName(kind: windows_shell.ProfileKind) []const u8 {
    return switch (kind.source()) {
        .detected => "detected",
        .config => "config",
        .visual_studio => "visual-studio",
    };
}

fn entriesOf(alloc: Allocator, profiles: []const windows_shell.Profile) Allocator.Error![]Entry {
    const entries = try alloc.alloc(Entry, profiles.len);
    for (profiles, entries) |profile, *entry| entry.* = .{
        .key = try validUtf8(alloc, profile.key),
        .label = try validUtf8(alloc, profile.label),
        .source = sourceName(profile.kind),
        .hidden = profile.hidden,
    };
    return entries;
}

/// `text` as valid UTF-8, each byte outside a well-formed sequence replaced
/// by U+FFFD. A Visual Studio nickname can hold a lone surrogate and WSL's
/// output can fall back to raw bytes, and `std.json` writes a string that is
/// not UTF-8 as an array of numbers.
fn validUtf8(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;
    var valid: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 0;
        if (len > 0 and index + len <= text.len and std.unicode.utf8ValidateSlice(text[index..][0..len])) {
            try valid.appendSlice(alloc, text[index..][0..len]);
            index += len;
        } else {
            try valid.appendSlice(alloc, "\u{fffd}");
            index += 1;
        }
    }
    return valid.items;
}

fn writeProfiles(
    alloc: Allocator,
    writer: *std.Io.Writer,
    style: Style,
    discovery: windows_shell.ProfileDiscovery,
) !void {
    const entries = try entriesOf(alloc, discovery.profiles);
    switch (style) {
        .json => try writeJson(writer, entries, discovery.complete),
        .plain => for (entries) |entry| {
            try writeClean(writer, entry.key);
            try writer.writeByte('\t');
            try writeClean(writer, entry.label);
            try writer.print("\t{s}\t{s}\n", .{ entry.source, entry.state() });
        },
        .table => try writeTable(writer, entries),
    }
}

fn writeJson(writer: *std.Io.Writer, entries: []const Entry, complete: bool) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .escape_unicode = true } };
    try json.beginObject();
    try json.objectField("schema");
    try json.write(json_schema);
    try json.objectField("complete");
    try json.write(complete);
    try json.objectField("profiles");
    try json.beginArray();
    for (entries) |entry| {
        try json.beginObject();
        try json.objectField("key");
        try json.write(entry.key);
        try json.objectField("label");
        try json.write(entry.label);
        try json.objectField("source");
        try json.write(entry.source);
        try json.objectField("hidden");
        try json.write(entry.hidden);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
}

/// Columns padded to their longest entry, two spaces apart. The last column
/// ends its line.
fn writeTable(writer: *std.Io.Writer, entries: []const Entry) !void {
    var key_width = "KEY".len;
    var label_width = "LABEL".len;
    var source_width = "SOURCE".len;
    for (entries) |entry| {
        key_width = @max(key_width, displayWidth(entry.key));
        label_width = @max(label_width, displayWidth(entry.label));
        source_width = @max(source_width, entry.source.len);
    }

    try writePadded(writer, "KEY", key_width);
    try writePadded(writer, "LABEL", label_width);
    try writePadded(writer, "SOURCE", source_width);
    try writer.writeAll("STATE\n");
    for (entries) |entry| {
        try writePadded(writer, entry.key, key_width);
        try writePadded(writer, entry.label, label_width);
        try writePadded(writer, entry.source, source_width);
        try writer.print("{s}\n", .{entry.state()});
    }
}

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writeClean(writer, text);
    try writer.splatByteAll(' ', width - displayWidth(text) + 2);
}

/// Code points, which is how wide the text is for the common case; wide and
/// combining characters still shift a column.
fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// `text` (valid UTF-8) with every control character replaced by `?`: a tab
/// or a newline would shift the fields, and an escape, or a C1 control that
/// some terminals read from UTF-8, would start a sequence on the reader's
/// terminal. A label comes from a config file, WSL or Visual Studio, so it
/// is not ours.
fn writeClean(writer: *std.Io.Writer, text: []const u8) !void {
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        const control_len: usize = if (byte < 0x20 or byte == 0x7f)
            1
        else if (byte == 0xc2 and index + 1 < text.len and text[index + 1] >= 0x80 and text[index + 1] <= 0x9f)
            2 // U+0080 to U+009F
        else
            0;
        if (control_len == 0) {
            index += 1;
            continue;
        }
        try writer.writeAll(text[start..index]);
        try writer.writeByte('?');
        index += control_len;
        start = index;
    }
    try writer.writeAll(text[start..]);
}

const testing = std.testing;

/// Profiles for the tests, in the order the picker would show them. Each
/// carries a command line, an argument, a working directory and a variable
/// that must never reach the output (`secrets`).
const test_profiles = [_]windows_shell.Profile{
    .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{ "C:\\secret-dir\\pwsh.exe", "--secret-arg" } },
    },
    .{
        .kind = .user,
        .key = "user:py312",
        .label = "Python 3.12",
        .command = .{ .direct = &.{ "C:\\secret-dir\\py.exe", "--secret-arg" } },
        .working_directory = .{ .path = "C:\\secret-dir\\work" },
        .user = .{
            .command_line = "C:\\secret-dir\\py.exe --secret-arg",
            .env = &.{.{ .key = "SECRET_KEY", .value = "secret-value" }},
        },
    },
    .{
        .kind = .vs_dev_cmd,
        .key = "vs:6bb7cfd9:cmd",
        .label = "Developer Command Prompt for VS 2022",
        .command = .{ .direct = &.{ "C:\\secret-dir\\cmd.exe", "/k", "--secret-arg" } },
    },
    .{
        .kind = .ssh,
        .key = "ssh:build-01",
        .label = "SSH: build-01",
        .command = .{ .direct = &.{ "C:\\secret-dir\\ssh.exe", "build-01" } },
        .hidden = true,
    },
};

const secrets = [_][]const u8{ "secret-dir", "secret-arg", "SECRET_KEY", "secret-value" };

fn testDiscover(_: Allocator) anyerror!windows_shell.ProfileDiscovery {
    return .{ .profiles = @constCast(&test_profiles), .complete = true };
}

fn testDiscoverIncomplete(_: Allocator) anyerror!windows_shell.ProfileDiscovery {
    return .{ .profiles = @constCast(test_profiles[0..1]), .complete = false };
}

fn failDiscover(_: Allocator) anyerror!windows_shell.ProfileDiscovery {
    return error.DiscoveryMustNotRun;
}

const TestRun = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: TestRun) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

fn testRun(command_line: []const u8, stdout_is_tty: bool, discover: DiscoverFn) !TestRun {
    var iter = try std.process.ArgIteratorGeneral(.{}).init(testing.allocator, command_line);
    defer iter.deinit();
    var stdout = std.Io.Writer.Allocating.init(testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr.deinit();
    const exit_code = try runArgs(
        testing.allocator,
        &iter,
        &stdout.writer,
        &stderr.writer,
        stdout_is_tty,
        discover,
    );
    return .{
        .exit_code = exit_code,
        .stdout = try testing.allocator.dupe(u8, stdout.written()),
        .stderr = try testing.allocator.dupe(u8, stderr.written()),
    };
}

/// `profiles` written in `style` into a buffer that `out` owns.
fn testWrite(out: *std.Io.Writer.Allocating, style: Style, profiles: []const windows_shell.Profile) !void {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    out.clearRetainingCapacity();
    try writeProfiles(arena.allocator(), &out.writer, style, .{ .profiles = @constCast(profiles), .complete = true });
}

fn expectNoSecrets(text: []const u8) !void {
    for (secrets) |secret| {
        if (std.mem.indexOf(u8, text, secret) != null) {
            std.debug.print("output holds \"{s}\":\n{s}\n", .{ secret, text });
            return error.TestUnexpectedResult;
        }
    }
}

test "list-profiles prints tab-separated lines when the output is not a terminal" {
    const run_result = try testRun("", false, testDiscover);
    defer run_result.deinit();
    try testing.expectEqual(@as(u8, 0), run_result.exit_code);
    try testing.expectEqualStrings(
        "pwsh.exe\tPowerShell\tdetected\tshown\n" ++
            "user:py312\tPython 3.12\tconfig\tshown\n" ++
            "vs:6bb7cfd9:cmd\tDeveloper Command Prompt for VS 2022\tvisual-studio\tshown\n" ++
            "ssh:build-01\tSSH: build-01\tdetected\thidden\n",
        run_result.stdout,
    );
    try testing.expectEqualStrings("", run_result.stderr);
    try expectNoSecrets(run_result.stdout);
}

test "list-profiles prints an aligned table on a terminal and --plain turns it off" {
    const table = try testRun("", true, testDiscover);
    defer table.deinit();
    try testing.expectEqual(@as(u8, 0), table.exit_code);
    try testing.expectEqualStrings(
        "KEY              LABEL                                 SOURCE         STATE\n" ++
            "pwsh.exe         PowerShell                            detected       shown\n" ++
            "user:py312       Python 3.12                           config         shown\n" ++
            "vs:6bb7cfd9:cmd  Developer Command Prompt for VS 2022  visual-studio  shown\n" ++
            "ssh:build-01     SSH: build-01                         detected       hidden\n",
        table.stdout,
    );
    try expectNoSecrets(table.stdout);

    const plain = try testRun("--plain", true, testDiscover);
    defer plain.deinit();
    const piped = try testRun("", false, testDiscover);
    defer piped.deinit();
    try testing.expectEqualStrings(piped.stdout, plain.stdout);
    try testing.expect(std.mem.indexOf(u8, plain.stdout, "KEY") == null);
}

test "list-profiles prints one JSON document that lists the profiles in order" {
    for ([_]bool{ true, false }) |tty| {
        const run_result = try testRun("--format=json", tty, testDiscover);
        defer run_result.deinit();
        try testing.expectEqual(@as(u8, 0), run_result.exit_code);
        try testing.expectEqualStrings(
            "{\"schema\":\"noctty.profiles.v1\",\"complete\":true,\"profiles\":[" ++
                "{\"key\":\"pwsh.exe\",\"label\":\"PowerShell\",\"source\":\"detected\",\"hidden\":false}," ++
                "{\"key\":\"user:py312\",\"label\":\"Python 3.12\",\"source\":\"config\",\"hidden\":false}," ++
                "{\"key\":\"vs:6bb7cfd9:cmd\",\"label\":\"Developer Command Prompt for VS 2022\",\"source\":\"visual-studio\",\"hidden\":false}," ++
                "{\"key\":\"ssh:build-01\",\"label\":\"SSH: build-01\",\"source\":\"detected\",\"hidden\":true}" ++
                "]}\n",
            run_result.stdout,
        );
        try expectNoSecrets(run_result.stdout);
    }

    // `--plain` has nothing to say to JSON, and `--format=text` is the default.
    const both = try testRun("--plain --format=json", true, testDiscover);
    defer both.deinit();
    try testing.expect(std.mem.startsWith(u8, both.stdout, "{\"schema\""));
    const text = try testRun("--format=text", false, testDiscover);
    defer text.deinit();
    try testing.expect(std.mem.startsWith(u8, text.stdout, "pwsh.exe\t"));
}

test "list-profiles keeps a label from shifting a column or writing an escape" {
    const profiles = [_]windows_shell.Profile{.{
        .kind = .user,
        .key = "user:odd",
        // A tab, an escape sequence, a bell, a newline, DEL and U+0085 (a C1
        // control that some terminals read from UTF-8).
        .label = "a\tb\x1b]0;x\x07c\nd\x7f\u{85}e",
        .command = .{ .direct = &.{} },
    }};
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    try testWrite(&out, .plain, &profiles);
    try testing.expectEqualStrings("user:odd\ta?b?]0;x?c?d??e\tconfig\tshown\n", out.written());

    try testWrite(&out, .table, &profiles);
    try testing.expect(std.mem.indexOf(u8, out.written(), "a?b?]0;x?c?d??e") != null);
    for (out.written()) |byte| try testing.expect(byte == '\n' or (byte >= 0x20 and byte != 0x7f));

    // JSON escapes them instead, which is inert in a terminal.
    try testWrite(&out, .json, &profiles);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"label\":\"a\\tb\\u001b]0;x\\u0007c\\nd\\u007f\\u0085e\"") != null);
}

test "list-profiles writes a label that is not UTF-8 as a string in every style" {
    const profiles = [_]windows_shell.Profile{.{
        .kind = .vs_dev_cmd,
        .key = "vs:1:cmd",
        // A lone surrogate as WTF-8 (a Visual Studio nickname), a stray
        // continuation byte and a sequence cut short at the end.
        .label = "VS \xed\xa0\x80 \x80 end\xe2\x82",
        .command = .{ .direct = &.{} },
    }};
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    try testWrite(&out, .json, &profiles);
    try testing.expectEqualStrings(
        "{\"schema\":\"noctty.profiles.v1\",\"complete\":true,\"profiles\":[{\"key\":\"vs:1:cmd\"," ++
            "\"label\":\"VS \\ufffd\\ufffd\\ufffd \\ufffd end\\ufffd\\ufffd\",\"source\":\"visual-studio\",\"hidden\":false}]}\n",
        out.written(),
    );

    try testWrite(&out, .plain, &profiles);
    try testing.expect(std.unicode.utf8ValidateSlice(out.written()));
    try testing.expectEqualStrings("vs:1:cmd\tVS \u{fffd}\u{fffd}\u{fffd} \u{fffd} end\u{fffd}\u{fffd}\tvisual-studio\tshown\n", out.written());
}

test "list-profiles writes the JSON as ASCII, so a console code page cannot garble it" {
    const profiles = [_]windows_shell.Profile{.{
        .kind = .wsl_distro,
        .key = "wsl:Caf\u{e9}",
        .label = "WSL: Caf\u{e9} \u{65e5}\u{672c} \u{1f600}",
        .command = .{ .direct = &.{} },
    }};
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testWrite(&out, .json, &profiles);
    for (out.written()) |byte| try testing.expect(byte < 0x80);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"label\":\"WSL: Caf\\u00e9 \\u65e5\\u672c \\ud83d\\ude00\"") != null);
}

test "list-profiles pads a table by characters, not bytes" {
    const profiles = [_]windows_shell.Profile{
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "WSL: Ubuntu", .command = .{ .direct = &.{} } },
        .{ .kind = .user, .key = "user:caf", .label = "Caf\u{e9} \u{65e5}\u{672c}", .command = .{ .direct = &.{} } },
    };
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testWrite(&out, .table, &profiles);
    try testing.expectEqualStrings(
        "KEY         LABEL        SOURCE    STATE\n" ++
            "wsl:Ubuntu  WSL: Ubuntu  detected  shown\n" ++
            "user:caf    Caf\u{e9} \u{65e5}\u{672c}      config    shown\n",
        out.written(),
    );
}

test "list-profiles says on stderr and in the JSON that the list may be incomplete" {
    const text = try testRun("", false, testDiscoverIncomplete);
    defer text.deinit();
    try testing.expectEqual(@as(u8, 0), text.exit_code);
    try testing.expectEqualStrings("pwsh.exe\tPowerShell\tdetected\tshown\n", text.stdout);
    try testing.expectEqualStrings(incomplete_note, text.stderr);

    const json = try testRun("--format=json", false, testDiscoverIncomplete);
    defer json.deinit();
    try testing.expect(std.mem.indexOf(u8, json.stdout, "\"complete\":false") != null);
    try testing.expectEqualStrings(incomplete_note, json.stderr);
}

test "list-profiles prints no profiles for an empty list" {
    const Empty = struct {
        fn discover(_: Allocator) anyerror!windows_shell.ProfileDiscovery {
            return .{ .profiles = &.{}, .complete = true };
        }
    };
    const plain = try testRun("", false, Empty.discover);
    defer plain.deinit();
    try testing.expectEqualStrings("", plain.stdout);
    const table = try testRun("", true, Empty.discover);
    defer table.deinit();
    try testing.expectEqualStrings("KEY  LABEL  SOURCE  STATE\n", table.stdout);
    const json = try testRun("--format=json", false, Empty.discover);
    defer json.deinit();
    try testing.expectEqualStrings(
        "{\"schema\":\"noctty.profiles.v1\",\"complete\":true,\"profiles\":[]}\n",
        json.stdout,
    );
}

test "list-profiles rejects what it does not take before it searches" {
    for ([_][]const u8{
        "--format=xml",
        "--plain=maybe",
        "--timeout=1",
        "unexpected",
    }) |command_line| {
        const run_result = try testRun(command_line, false, failDiscover);
        defer run_result.deinit();
        try testing.expectEqual(@as(u8, 1), run_result.exit_code);
        try testing.expectEqualStrings("", run_result.stdout);
        try testing.expect(std.mem.startsWith(u8, run_result.stderr, "Error parsing +list-profiles arguments:"));
    }
}

test "list-profiles asks for help" {
    try testing.expectError(error.ActionHelpRequested, testRun("--help", false, failDiscover));
}

test "list-profiles asks discovery with the configuration's profile and SSH settings" {
    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();
    const arena = config._arena.?.allocator();
    try config.@"profile-command".parseCLI(arena, "py: cmd.exe /k py");
    try config.@"profile-command".parseCLI(arena, "gone: cmd.exe");
    try config.@"profile-command".parseCLI(arena, "gone:");
    try config.@"profile-order".parseCLI(arena, "ssh:prod");
    try config.@"profile-order".parseCLI(arena, "py");
    try config.@"profile-hidden".parseCLI(arena, "pwsh.exe");
    config.@"visual-studio-profiles" = .all;

    const Probe = struct {
        var include_ssh_hosts: ?bool = null;
        var definitions: usize = 0;
        var first_is_py = false;
        var order: usize = 0;
        var hidden: usize = 0;
        var visual_studio: windows_shell.VisualStudioProfiles = .newest;

        fn discover(
            _: Allocator,
            include: bool,
            user: *const windows_shell.UserProfiles,
        ) anyerror!windows_shell.ProfileDiscovery {
            include_ssh_hosts = include;
            definitions = user.definitions.len;
            // The definitions are freed when discovery returns: read them here.
            first_is_py = user.definitions.len > 0 and std.mem.eql(u8, user.definitions[0].id, "py");
            order = user.order.len;
            hidden = user.hidden.len;
            visual_studio = user.visual_studio;
            return .{ .profiles = &.{}, .complete = true };
        }
    };

    // Both settings of `ssh-config-hosts` reach discovery as they are.
    for ([_]bool{ false, true }) |ssh| {
        config.@"ssh-config-hosts" = ssh;
        Probe.include_ssh_hosts = null;
        _ = try discoverForConfig(testing.allocator, &config, Probe.discover);
        try testing.expectEqual(@as(?bool, ssh), Probe.include_ssh_hosts);
    }
    // A removed profile is not a definition; the rest comes through whole.
    try testing.expectEqual(@as(usize, 1), Probe.definitions);
    try testing.expect(Probe.first_is_py);
    try testing.expectEqual(@as(usize, 2), Probe.order);
    try testing.expectEqual(@as(usize, 1), Probe.hidden);
    try testing.expectEqual(windows_shell.VisualStudioProfiles.all, Probe.visual_studio);
}

test "list-profiles applies the color scheme Windows reports before it asks discovery" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Theme files that set the profile keys the picker reads, differently;
    // the main file sets none of them. `Config.load` leaves the config in
    // the light state, so without the scheme a dark desktop lists the light
    // theme's profiles.
    try tmp.dir.writeFile(.{ .sub_path = "light", .data = "profile-hidden = cmd\nssh-config-hosts = true\nvisual-studio-profiles = none\n" });
    try tmp.dir.writeFile(.{
        .sub_path = "dark",
        .data = "profile-command = darkonly: cmd.exe /k dark\nprofile-order = darkonly\n" ++
            "profile-hidden = pwsh\nprofile-hidden = wsl\nssh-config-hosts = false\nvisual-studio-profiles = all\n",
    });
    const light_path = try tmp.dir.realpathAlloc(alloc, "light");
    defer alloc.free(light_path);
    const dark_path = try tmp.dir.realpathAlloc(alloc, "dark");
    defer alloc.free(dark_path);
    const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\n", .{ light_path, dark_path });
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "main.ghostty", .data = text });
    const main_path = try tmp.dir.realpathAlloc(alloc, "main.ghostty");
    defer alloc.free(main_path);

    var config = try configpkg.Config.default(alloc);
    defer config.deinit();
    try config.loadFile(alloc, main_path);
    try config.loadRecursiveFiles(alloc);
    try config.finalize();
    try testing.expect(config._diagnostics.empty());

    const Seen = struct {
        include_ssh_hosts: bool = false,
        definitions: usize = 0,
        first_hidden_is: u8 = 0,
        order: usize = 0,
        visual_studio: windows_shell.VisualStudioProfiles = .newest,
    };
    const Probe = struct {
        var seen: Seen = .{};

        // The snapshot is freed when discovery returns: read it here.
        fn discover(
            _: Allocator,
            include: bool,
            user: *const windows_shell.UserProfiles,
        ) anyerror!windows_shell.ProfileDiscovery {
            seen = .{
                .include_ssh_hosts = include,
                .definitions = user.definitions.len,
                .first_hidden_is = if (user.hidden.len > 0) user.hidden[0][0] else 0,
                .order = user.order.len,
                .visual_studio = user.visual_studio,
            };
            return .{ .profiles = &.{}, .complete = true };
        }
    };

    _ = try discoverForScheme(alloc, &config, .light, Probe.discover);
    try testing.expectEqual(Seen{
        .include_ssh_hosts = true,
        .definitions = 0,
        .first_hidden_is = 'c',
        .order = 0,
        .visual_studio = .none,
    }, Probe.seen);

    _ = try discoverForScheme(alloc, &config, .dark, Probe.discover);
    try testing.expectEqual(Seen{
        .include_ssh_hosts = false,
        .definitions = 1,
        .first_hidden_is = 'p',
        .order = 1,
        .visual_studio = .all,
    }, Probe.seen);

    // What `Config.load` hands over, unapplied, is the light state's: the
    // dark theme's settings are reached only by applying the scheme.
    _ = try discoverForConfig(alloc, &config, Probe.discover);
    try testing.expectEqual(@as(usize, 0), Probe.seen.definitions);
    try testing.expect(Probe.seen.include_ssh_hosts);

    // The scheme was applied to a copy: asking again for light still works.
    _ = try discoverForScheme(alloc, &config, .light, Probe.discover);
    try testing.expectEqual(@as(usize, 0), Probe.seen.definitions);
}

test "list-profiles is a registered action with help text" {
    const help_strings = @import("help_strings");
    const ghostty_action = @import("ghostty_action.zig");
    try testing.expect(std.meta.stringToEnum(ghostty_action.Action, "list-profiles") != null);
    try testing.expectEqualStrings("cli/list_profiles.zig", comptime ghostty_action.Action.file(.@"list-profiles"));
    try testing.expect(@hasDecl(help_strings.Action, "list-profiles"));
    try testing.expect(std.mem.indexOf(u8, help_strings.Action.@"list-profiles", "never prints") != null);
}

test "every kind of profile has a source" {
    const Kind = windows_shell.ProfileKind;
    const expected = [_]struct { Kind, []const u8 }{
        .{ .wsl_default, "detected" },
        .{ .wsl_distro, "detected" },
        .{ .pwsh, "detected" },
        .{ .powershell, "detected" },
        .{ .git_bash, "detected" },
        .{ .cmd, "detected" },
        .{ .ssh, "detected" },
        .{ .user, "config" },
        .{ .vs_dev_cmd, "visual-studio" },
        .{ .vs_dev_shell, "visual-studio" },
    };
    try testing.expectEqual(@typeInfo(Kind).@"enum".fields.len, expected.len);
    for (expected) |entry| try testing.expectEqualStrings(entry[1], sourceName(entry[0]));
}
