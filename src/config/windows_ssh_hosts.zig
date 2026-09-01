const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win = @import("../os/windows.zig");
const log = std.log.scoped(.windows_ssh_hosts);

pub const max_hosts: usize = 256;
pub const max_file_size: usize = 1024 * 1024;
pub const max_alias_len: usize = 255;
pub const max_include_files: usize = 16;
const include_read_budget_ns: u64 = 50 * std.time.ns_per_ms;

var read_warning_mutex: std.Thread.Mutex = .{};
var read_warning_logged = false;
var include_read_in_progress: std.atomic.Value(bool) = .init(false);

pub const Host = struct {
    alias: []const u8,

    pub fn deinit(self: *Host, alloc: Allocator) void {
        alloc.free(self.alias);
    }
};

pub fn deinitHosts(alloc: Allocator, hosts: []Host) void {
    for (hosts) |*host| host.deinit(alloc);
    alloc.free(hosts);
}

pub fn parse(alloc: Allocator, contents: []const u8) ![]Host {
    var hosts: std.ArrayList(Host) = .empty;
    errdefer deinitHostList(alloc, &hosts);
    try parseInto(alloc, &hosts, contents, null, 0);
    return try hosts.toOwnedSlice(alloc);
}

/// Resolves the directory `ssh` itself expands `~` to on Windows: `%USERPROFILE%`,
/// falling back to the profile known folder.
///
/// Deliberately NOT `homedir.home`, which prefers `HOMEDRIVE`+`HOMEPATH`. On a
/// domain-joined machine with a redirected home those point at a network share,
/// so we would parse a different config than Win32-OpenSSH reads and list
/// aliases `ssh` cannot resolve.
pub fn userProfileDir(buf: []u8) !?[]const u8 {
    var fba_instance = std.heap.FixedBufferAllocator.init(buf);
    const fba = fba_instance.allocator();
    if (std.process.getEnvVarOwned(fba, "USERPROFILE")) |value| {
        if (value.len > 0) return value;
    } else |err| switch (err) {
        error.OutOfMemory => return error.BufferTooSmall,
        error.InvalidWtf8, error.EnvironmentVariableNotFound => {},
    }
    return try win.knownFolderPathUtf8(&win.FOLDERID_Profile, buf);
}

pub fn load(alloc: Allocator) ![]Host {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_dir = (userProfileDir(&home_buf) catch null) orelse
        return try alloc.alloc(Host, 0);
    return try loadFromHome(alloc, home_dir);
}

fn loadFromHome(alloc: Allocator, home_dir: []const u8) ![]Host {
    const ssh_dir = try std.fs.path.join(alloc, &.{ home_dir, ".ssh" });
    defer alloc.free(ssh_dir);
    const config_path = try std.fs.path.join(alloc, &.{ ssh_dir, "config" });
    defer alloc.free(config_path);

    var hosts: std.ArrayList(Host) = .empty;
    errdefer deinitHostList(alloc, &hosts);
    var load_context: LoadContext = .{
        .alloc = alloc,
        .home_dir = home_dir,
        .ssh_dir = ssh_dir,
        .hosts = &hosts,
        .include_read_started_ns = std.time.nanoTimestamp(),
    };
    try load_context.parseFile(config_path, 0);
    return try hosts.toOwnedSlice(alloc);
}

const LoadContext = struct {
    alloc: Allocator,
    home_dir: []const u8,
    ssh_dir: []const u8,
    hosts: *std.ArrayList(Host),
    includes_read: usize = 0,
    include_read_started_ns: i128,

    fn parseFile(self: *LoadContext, path: []const u8, depth: u8) Allocator.Error!void {
        const contents = readFile(self.alloc, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return,
            else => {
                warnReadOnce(path, err);
                return;
            },
        };
        defer self.alloc.free(contents);
        try parseInto(self.alloc, self.hosts, contents, self, depth);
    }

    fn parseIncludes(self: *LoadContext, value: []const u8, depth: u8) Allocator.Error!void {
        if (depth >= 1) return;

        var paths: SshArgIterator = .{ .value = value };
        while (try paths.next(self.alloc)) |raw_path| {
            defer self.alloc.free(raw_path);
            if (raw_path.len == 0) continue;
            if (hasGlobMetacharacter(raw_path)) continue;
            // This read is synchronous on the UI thread and runs on every
            // profile refresh — app startup, every picker open, and the first
            // pane of every restored session window. A remote or device path
            // could block on an SMB/TCP timeout, and an uncapped include count
            // would multiply that.
            if (isUnsupportedIncludePath(raw_path)) {
                warnReadOnce(raw_path, error.UnsupportedIncludePath);
                continue;
            }
            if (self.includes_read >= max_include_files) return;
            self.includes_read += 1;

            const path = if (std.mem.startsWith(u8, raw_path, "~/") or
                std.mem.startsWith(u8, raw_path, "~\\"))
                try std.fs.path.join(self.alloc, &.{ self.home_dir, raw_path[2..] })
            else if (std.fs.path.isAbsolute(raw_path))
                try self.alloc.dupe(u8, raw_path)
            else
                try std.fs.path.join(self.alloc, &.{ self.ssh_dir, raw_path });
            defer self.alloc.free(path);

            const elapsed_ns = @max(std.time.nanoTimestamp() - self.include_read_started_ns, 0);
            if (elapsed_ns >= include_read_budget_ns) return;
            const remaining_ns: u64 = @intCast(include_read_budget_ns - elapsed_ns);
            const contents = (readIncludeFileBounded(
                self.alloc,
                path,
                remaining_ns,
                readFile,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    warnReadOnce(path, err);
                    continue;
                },
            }) orelse {
                warnReadOnce(path, error.IncludeReadTimedOut);
                return;
            };
            defer self.alloc.free(contents);
            try parseInto(self.alloc, self.hosts, contents, self, depth + 1);
            if (self.hosts.items.len >= max_hosts) return;
        }
    }
};

const Directive = struct {
    keyword: []const u8,
    value: []const u8,
};

/// Tokenizes the argument portion of an OpenSSH configuration directive.
/// Double quotes may begin anywhere in an argument, are removed, and group
/// whitespace until the matching quote. An unterminated quote consumes the
/// remainder, matching OpenSSH's `strdelim` behavior. Backslashes and single
/// quotes remain literal so Windows paths are not corrupted.
const SshArgIterator = struct {
    value: []const u8,
    index: usize = 0,
    backslash_escape: bool = false,

    fn next(self: *SshArgIterator, alloc: Allocator) Allocator.Error!?[]u8 {
        while (self.index < self.value.len and
            (self.value[self.index] == ' ' or self.value[self.index] == '\t')) : (self.index += 1)
        {}
        if (self.index >= self.value.len) return null;

        var token: std.ArrayList(u8) = .empty;
        errdefer token.deinit(alloc);
        var quoted = false;
        while (self.index < self.value.len) {
            const c = self.value[self.index];
            if (self.backslash_escape and c == '\\' and self.index + 1 < self.value.len) {
                try token.append(alloc, self.value[self.index + 1]);
                self.index += 2;
                continue;
            }
            if (c == '"') {
                quoted = !quoted;
                self.index += 1;
                continue;
            }
            if (!quoted and (c == ' ' or c == '\t')) break;
            try token.append(alloc, c);
            self.index += 1;
        }
        return try token.toOwnedSlice(alloc);
    }
};

fn parseInto(
    alloc: Allocator,
    hosts: *std.ArrayList(Host),
    raw_contents: []const u8,
    load_context: ?*LoadContext,
    depth: u8,
) Allocator.Error!void {
    const contents = if (std.mem.startsWith(u8, raw_contents, "\xEF\xBB\xBF"))
        raw_contents[3..]
    else
        raw_contents;
    var in_match = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const directive = parseDirective(raw_line) orelse continue;
        if (std.ascii.eqlIgnoreCase(directive.keyword, "match")) {
            in_match = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(directive.keyword, "include")) {
            // A Match block's includes are conditional on runtime state we do
            // not evaluate, so they are skipped rather than guessed at.
            if (!in_match) {
                if (load_context) |context| try context.parseIncludes(directive.value, depth);
            }
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(directive.keyword, "host")) continue;

        in_match = false;
        var aliases: SshArgIterator = .{ .value = directive.value, .backslash_escape = true };
        while (try aliases.next(alloc)) |alias| {
            defer alloc.free(alias);
            if (hosts.items.len >= max_hosts) break;
            if (!isConnectableAlias(alias)) continue;
            // Repeated stanzas for one alias are legal ssh_config, but a
            // second entry would collide on the palette's stable id and
            // could exhaust `max_hosts` ahead of later unique aliases.
            if (containsAlias(hosts.items, alias)) continue;
            try hosts.ensureUnusedCapacity(alloc, 1);
            hosts.appendAssumeCapacity(.{ .alias = try alloc.dupe(u8, alias) });
        }
    }
}

fn parseDirective(raw_line: []const u8) ?Directive {
    var line = std.mem.trim(u8, raw_line, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    if (sshCommentStart(line)) |comment_start| {
        line = std.mem.trimRight(u8, line[0..comment_start], " \t\r");
    }
    if (line.len == 0) return null;

    var keyword_end: usize = 0;
    while (keyword_end < line.len and
        line[keyword_end] != '=' and
        line[keyword_end] != ' ' and
        line[keyword_end] != '\t') : (keyword_end += 1)
    {}
    if (keyword_end == 0) return null;

    var value_start = keyword_end;
    while (value_start < line.len and
        (line[value_start] == ' ' or line[value_start] == '\t')) : (value_start += 1)
    {}
    if (value_start < line.len and line[value_start] == '=') value_start += 1;
    while (value_start < line.len and
        (line[value_start] == ' ' or line[value_start] == '\t')) : (value_start += 1)
    {}

    return .{
        .keyword = line[0..keyword_end],
        .value = std.mem.trimRight(u8, line[value_start..], " \t\r"),
    };
}

fn sshCommentStart(line: []const u8) ?usize {
    var quoted = false;
    for (line, 0..) |c, i| {
        if (c == '"') {
            quoted = !quoted;
            continue;
        }
        if (c == '#' and !quoted and
            (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t'))
        {
            return i;
        }
    }
    return null;
}

fn containsAlias(hosts: []const Host, alias: []const u8) bool {
    for (hosts) |host| {
        if (std.mem.eql(u8, host.alias, alias)) return true;
    }
    return false;
}

/// An accepted alias is passed to `ssh.exe` as one literal argv element, so a
/// leading `-` (which would become an ssh option) is refused. The shell
/// metacharacters are refused as well: an explicit `shell-integration` mode can
/// still rewrite a direct argv into a `cmd.exe /C` string elsewhere in the
/// launch path, where `&` or `|` would separate commands.
fn isConnectableAlias(alias: []const u8) bool {
    if (alias.len == 0 or alias.len > max_alias_len) return false;
    if (alias[0] == '-') return false;
    for (alias) |c| {
        if (std.mem.indexOfScalar(u8, "*?!'\"&|<>^%();,$`", c) != null) return false;
        if (std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
        // `std.ascii.isControl` stops at 0x7F, so 0x80-0xFF would otherwise
        // pass through into display strings that are converted to UTF-16.
        if (c >= 0x80) return false;
    }
    return true;
}

const DRIVE_REMOTE: u32 = 4;

extern "kernel32" fn GetDriveTypeW(root_path: ?[*:0]const u16) callconv(.winapi) u32;

/// Every include path we refuse to open from the UI thread.
fn isUnsupportedIncludePath(path: []const u8) bool {
    return isRemoteOrDevicePath(path) or isRemoteDriveLetter(path);
}

/// UNC (`\\server\share`) and device (`\\?\`, `\\.\`) namespaces, in either
/// slash spelling.
fn isRemoteOrDevicePath(path: []const u8) bool {
    if (path.len < 2) return false;
    const a = path[0];
    const b = path[1];
    return (a == '\\' or a == '/') and (b == '\\' or b == '/');
}

/// The `X` of an `X:\` or `X:/` absolute path, uppercased. Null for anything
/// else, including a bare `X:` relative-to-current-directory spelling, which
/// `std.fs.path.isAbsolute` also rejects.
fn driveLetter(path: []const u8) ?u8 {
    if (path.len < 3) return null;
    if (!std.ascii.isAlphabetic(path[0])) return null;
    if (path[1] != ':') return null;
    if (path[2] != '\\' and path[2] != '/') return null;
    return std.ascii.toUpper(path[0]);
}

/// A mapped network drive (`Z:\ssh\hosts.conf`) is syntactically a plain local
/// absolute path, so `isRemoteOrDevicePath` cannot see it. Opening one whose
/// SMB server is gone blocks the UI thread for a full network timeout.
///
/// `GetDriveTypeW` answers from the process's local mount table and does not
/// contact the server, so it cannot itself block on a dead mapping.
///
/// This does NOT cover a directory junction or a `subst` alias whose target is
/// remote: those report the drive type of the letter, not of the target.
fn isRemoteDriveLetter(path: []const u8) bool {
    if (comptime builtin.os.tag != .windows) {
        return false;
    } else {
        const letter = driveLetter(path) orelse return false;
        const root = [_]u16{ letter, ':', '\\', 0 };
        return GetDriveTypeW(root[0..3 :0]) == DRIVE_REMOTE;
    }
}

fn hasGlobMetacharacter(path: []const u8) bool {
    return std.mem.indexOfAny(u8, path, "*?[]") != null;
}

fn readFile(alloc: Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > max_file_size) return error.FileTooBig;
    return try file.readToEndAlloc(alloc, max_file_size);
}

const ReadFileFn = *const fn (Allocator, []const u8) anyerror![]u8;

const AsyncIncludeRead = struct {
    refs: std.atomic.Value(u32) = .init(2),
    mutex: std.Thread.Mutex = .{},
    done_cond: std.Thread.Condition = .{},
    done: bool = false,
    path: []u8,
    read_fn: ReadFileFn,
    data: ?[]u8 = null,
    err: ?anyerror = null,

    fn release(self: *@This()) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = std.heap.page_allocator;
        alloc.free(self.path);
        if (self.data) |data| alloc.free(data);
        alloc.destroy(self);
    }

    fn run(self: *@This()) void {
        const alloc = std.heap.page_allocator;
        const result = self.read_fn(alloc, self.path);

        self.mutex.lock();
        if (result) |data| {
            self.data = data;
        } else |err| {
            self.err = err;
        }
        include_read_in_progress.store(false, .release);
        self.done = true;
        self.done_cond.broadcast();
        self.mutex.unlock();

        self.release();
    }
};

/// Runs an Include open away from the caller and waits only for the remaining
/// per-refresh budget. A timed-out worker owns all of its memory until it
/// finishes. Only one may exist at a time, so a dead network mapping cannot
/// create an unbounded thread or allocation leak across picker refreshes.
fn readIncludeFileBounded(
    alloc: Allocator,
    path: []const u8,
    timeout_ns: u64,
    read_fn: ReadFileFn,
) !?[]u8 {
    if (timeout_ns == 0) return null;
    if (include_read_in_progress.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return null;
    }

    const worker_alloc = std.heap.page_allocator;
    const owned_path = worker_alloc.dupe(u8, path) catch |err| {
        include_read_in_progress.store(false, .release);
        return err;
    };
    const request = worker_alloc.create(AsyncIncludeRead) catch |err| {
        worker_alloc.free(owned_path);
        include_read_in_progress.store(false, .release);
        return err;
    };
    request.* = .{ .path = owned_path, .read_fn = read_fn };

    const thread = std.Thread.spawn(.{}, AsyncIncludeRead.run, .{request}) catch |err| {
        request.refs.store(1, .monotonic);
        include_read_in_progress.store(false, .release);
        request.release();
        return err;
    };
    thread.detach();
    defer request.release();

    request.mutex.lock();
    if (!request.done) {
        request.done_cond.timedWait(&request.mutex, timeout_ns) catch {
            request.mutex.unlock();
            return null;
        };
    }
    if (!request.done) {
        request.mutex.unlock();
        return null;
    }
    const data = request.data;
    request.data = null;
    const read_err = request.err;
    request.mutex.unlock();

    if (read_err) |err| return err;
    const worker_data = data orelse return error.UnexpectedEmptyRead;
    defer worker_alloc.free(worker_data);
    return try alloc.dupe(u8, worker_data);
}

fn warnReadOnce(path: []const u8, err: anyerror) void {
    read_warning_mutex.lock();
    defer read_warning_mutex.unlock();
    if (read_warning_logged) return;
    read_warning_logged = true;
    log.warn("SSH config unreadable path={s} err={}", .{ path, err });
}

fn deinitHostList(alloc: Allocator, hosts: *std.ArrayList(Host)) void {
    for (hosts.items) |*host| host.deinit(alloc);
    hosts.deinit(alloc);
}

test "ssh config parses concrete aliases and ignores non-Host directives" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const hosts = try parse(
        alloc,
        "\xEF\xBB\xBF# comment\r\n" ++
            "  hOsT alpha beta *.example !blocked ?single -oProxyCommand=calc \"quoted\" bad\x01alias # trailing\r\n" ++
            "HostName=server.example.com\r\n" ++
            "USER alice\r\n" ++
            "pOrT = 2222\r\n" ++
            "IdentityFile ignored\r\n" ++
            "Host gamma\r\n" ++
            "HostName gamma.example.com\r\n" ++
            "Match host gamma\r\n" ++
            "User must-not-leak\r\n" ++
            "Host delta epsilon\r\n" ++
            "Port 2200\r\n",
    );
    defer deinitHosts(alloc, hosts);

    try testing.expectEqual(@as(usize, 6), hosts.len);
    try testing.expectEqualStrings("alpha", hosts[0].alias);
    try testing.expectEqualStrings("beta", hosts[1].alias);
    try testing.expectEqualStrings("quoted", hosts[2].alias);
    try testing.expectEqualStrings("gamma", hosts[3].alias);
    try testing.expectEqualStrings("delta", hosts[4].alias);
    try testing.expectEqualStrings("epsilon", hosts[5].alias);
}

test "ssh config rejects non-ascii aliases that would reach a UTF-16 conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // 0xFF is neither ASCII control nor ASCII whitespace, and a lone 0xFF is
    // not valid UTF-8, so this must not survive into a display string.
    const hosts = try parse(alloc, "Host prod\xff latin\xe9 safe\n");
    defer deinitHosts(alloc, hosts);

    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("safe", hosts[0].alias);
    for (hosts) |host| try testing.expect(std.unicode.utf8ValidateSlice(host.alias));
}

test "ssh config rejects option-shaped quoted and control aliases" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const hosts = try parse(
        alloc,
        "Host -oProxyCommand=calc -p2222 \"quoted alias\" 'single quoted' escaped\\ alias control\x7falias safe\n",
    );
    defer deinitHosts(alloc, hosts);

    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("safe", hosts[0].alias);
}

test "ssh config rejects shell metacharacter and overlong aliases" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const long = try alloc.alloc(u8, max_alias_len + 1);
    defer alloc.free(long);
    @memset(long, 'a');
    const source = try std.fmt.allocPrint(
        alloc,
        "Host safe&calc.exe piped|calc redirect>out sub$(calc) semi;calc {s} safe\n",
        .{long},
    );
    defer alloc.free(source);

    const hosts = try parse(alloc, source);
    defer deinitHosts(alloc, hosts);

    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("safe", hosts[0].alias);
}

test "ssh config preserves case-distinct aliases and deduplicates exact repeats" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const hosts = try parse(
        alloc,
        "Host prod\nHostName one.example.com\nHost PROD staging\nHostName two.example.com\nHost prod\n",
    );
    defer deinitHosts(alloc, hosts);

    try testing.expectEqual(@as(usize, 3), hosts.len);
    try testing.expectEqualStrings("prod", hosts[0].alias);
    try testing.expectEqualStrings("PROD", hosts[1].alias);
    try testing.expectEqualStrings("staging", hosts[2].alias);
}

test "ssh config caps total concrete aliases" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    for (0..max_hosts + 32) |index| {
        const line = try std.fmt.allocPrint(alloc, "Host host-{d}\n", .{index});
        defer alloc.free(line);
        try source.appendSlice(alloc, line);
    }

    const hosts = try parse(alloc, source.items);
    defer deinitHosts(alloc, hosts);
    try testing.expectEqual(max_hosts, hosts.len);
}

test "ssh config parser cleans up every allocation failure" {
    const testing = std.testing;
    const run = struct {
        fn parseFixture(alloc: Allocator, contents: []const u8) !void {
            const hosts = try parse(alloc, contents);
            defer deinitHosts(alloc, hosts);
        }
    }.parseFixture;

    try testing.checkAllAllocationFailures(
        testing.allocator,
        run,
        .{"Host alpha beta\nHostName server.example.com\nUser deploy\nPort 2222\n"},
    );
}

test "ssh config loads one include level and resolves supported paths" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".ssh");
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/relative.conf", .data = "Include nested.conf\nHost relative\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/nested.conf", .data = "Host nested\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/tilde.conf", .data = "Host tilde\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/absolute.conf", .data = "Host absolute\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/globbed.conf", .data = "Host globbed\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/matched.conf", .data = "Host matched\n" });

    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);
    const absolute = try tmp.dir.realpathAlloc(alloc, ".ssh/absolute.conf");
    defer alloc.free(absolute);
    const root = try std.fmt.allocPrint(
        alloc,
        "Include relative.conf\nInclude ~/.ssh/tilde.conf\nInclude {s}\nInclude *.conf\nMatch all\nInclude matched.conf\nHost root\n",
        .{absolute},
    );
    defer alloc.free(root);
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/config", .data = root });

    const hosts = try loadFromHome(alloc, home);
    defer deinitHosts(alloc, hosts);
    try testing.expectEqual(@as(usize, 4), hosts.len);
    try testing.expectEqualStrings("relative", hosts[0].alias);
    try testing.expectEqualStrings("tilde", hosts[1].alias);
    try testing.expectEqualStrings("absolute", hosts[2].alias);
    try testing.expectEqualStrings("root", hosts[3].alias);
}

test "ssh config argument tokenizer follows OpenSSH quote boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var quoted: SshArgIterator = .{ .value = "\"C:\\Users\\Jane Doe\\.ssh\\work hosts\" plain.conf" };
    const quoted_path = (try quoted.next(alloc)).?;
    defer alloc.free(quoted_path);
    try testing.expectEqualStrings("C:\\Users\\Jane Doe\\.ssh\\work hosts", quoted_path);
    const plain_path = (try quoted.next(alloc)).?;
    defer alloc.free(plain_path);
    try testing.expectEqualStrings("plain.conf", plain_path);
    try testing.expect((try quoted.next(alloc)) == null);

    // Backslashes stay verbatim: they are path separators, not escapes.
    var backslashes: SshArgIterator = .{ .value = "C:\\Bob's\\config  ~/.ssh/x.conf" };
    const first_backslash = (try backslashes.next(alloc)).?;
    defer alloc.free(first_backslash);
    try testing.expectEqualStrings("C:\\Bob's\\config", first_backslash);
    const second_backslash = (try backslashes.next(alloc)).?;
    defer alloc.free(second_backslash);
    try testing.expectEqualStrings("~/.ssh/x.conf", second_backslash);
    try testing.expect((try backslashes.next(alloc)) == null);

    var embedded: SshArgIterator = .{ .value = "C:\\base\" dir\\hosts.conf\"" };
    const embedded_path = (try embedded.next(alloc)).?;
    defer alloc.free(embedded_path);
    try testing.expectEqualStrings("C:\\base dir\\hosts.conf", embedded_path);

    var unterminated: SshArgIterator = .{ .value = "\"C:\\never closed" };
    const unterminated_path = (try unterminated.next(alloc)).?;
    defer alloc.free(unterminated_path);
    try testing.expectEqualStrings("C:\\never closed", unterminated_path);

    var empty: SshArgIterator = .{ .value = "   \t " };
    try testing.expect((try empty.next(alloc)) == null);
}

test "ssh config preserves hashes and unquotes host aliases" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const hosts = try parse(
        alloc,
        "Host prod#bastion \"production\" # trailing comment\n",
    );
    defer deinitHosts(alloc, hosts);

    try testing.expectEqual(@as(usize, 2), hosts.len);
    try testing.expectEqualStrings("prod#bastion", hosts[0].alias);
    try testing.expectEqualStrings("production", hosts[1].alias);
}

test "ssh config loads a quoted include whose filename contains spaces" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".ssh");
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/work hosts.conf", .data = "Host spaced\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/plain.conf", .data = "Host plain\n" });
    try tmp.dir.writeFile(.{
        .sub_path = ".ssh/config",
        .data = "Include \"work hosts.conf\" plain.conf\nHost root\n",
    });

    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);
    const hosts = try loadFromHome(alloc, home);
    defer deinitHosts(alloc, hosts);

    try testing.expectEqual(@as(usize, 3), hosts.len);
    try testing.expectEqualStrings("spaced", hosts[0].alias);
    try testing.expectEqualStrings("plain", hosts[1].alias);
    try testing.expectEqualStrings("root", hosts[2].alias);
}

test "ssh config loads a quoted include whose filename contains a hash" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".ssh");
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/work#hosts.conf", .data = "Host hashed\n" });
    try tmp.dir.writeFile(.{
        .sub_path = ".ssh/config",
        .data = "Include \"work#hosts.conf\" # trailing comment\nHost root\n",
    });

    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);
    const hosts = try loadFromHome(alloc, home);
    defer deinitHosts(alloc, hosts);

    try testing.expectEqual(@as(usize, 2), hosts.len);
    try testing.expectEqualStrings("hashed", hosts[0].alias);
    try testing.expectEqualStrings("root", hosts[1].alias);
}

test "ssh config recognizes drive-letter roots for the remote-drive check" {
    const testing = std.testing;

    try testing.expectEqual(@as(?u8, 'Z'), driveLetter("Z:\\ssh\\hosts.conf"));
    try testing.expectEqual(@as(?u8, 'Z'), driveLetter("z:/ssh/hosts.conf"));
    try testing.expectEqual(@as(?u8, 'C'), driveLetter("C:\\"));
    // Not drive-letter roots: relative, UNC, and the `X:name` spelling that
    // resolves against the drive's current directory.
    try testing.expectEqual(@as(?u8, null), driveLetter("hosts.conf"));
    try testing.expectEqual(@as(?u8, null), driveLetter("Z:hosts.conf"));
    try testing.expectEqual(@as(?u8, null), driveLetter("\\\\server\\share\\x"));
    try testing.expectEqual(@as(?u8, null), driveLetter("~/.ssh/x.conf"));

    // The local system drive must never be misread as remote, or every
    // ordinary absolute include would be dropped.
    try testing.expect(!isRemoteDriveLetter("C:\\Users\\me\\.ssh\\hosts.conf"));
    try testing.expect(!isRemoteDriveLetter("hosts.conf"));
    try testing.expect(!isUnsupportedIncludePath("C:\\Users\\me\\.ssh\\hosts.conf"));
    try testing.expect(isUnsupportedIncludePath("\\\\10.0.0.1\\share\\hosts.conf"));
}

test "ssh config skips remote and device include paths without opening them" {
    const testing = std.testing;

    try testing.expect(isRemoteOrDevicePath("\\\\10.0.0.1\\x\\c"));
    try testing.expect(isRemoteOrDevicePath("//10.0.0.1/x/c"));
    try testing.expect(isRemoteOrDevicePath("\\\\?\\C:\\hosts.conf"));
    try testing.expect(isRemoteOrDevicePath("\\\\.\\pipe\\x"));
    try testing.expect(!isRemoteOrDevicePath("C:\\Users\\me\\.ssh\\hosts.conf"));
    try testing.expect(!isRemoteOrDevicePath("hosts.conf"));

    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".ssh");
    // A blocking SMB open here would hang the picker, so the path must be
    // rejected before `openFileAbsolute` is reached.
    try tmp.dir.writeFile(.{
        .sub_path = ".ssh/config",
        .data = "Include \\\\10.0.0.1\\share\\hosts.conf\nInclude \\\\?\\C:\\hosts.conf\nHost root\n",
    });
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    const hosts = try loadFromHome(alloc, home);
    defer deinitHosts(alloc, hosts);
    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("root", hosts[0].alias);
}

test "ssh config caps the number of include files read" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".ssh");

    var root: std.ArrayList(u8) = .empty;
    defer root.deinit(alloc);
    for (0..max_include_files + 8) |index| {
        const name = try std.fmt.allocPrint(alloc, "inc-{d}.conf", .{index});
        defer alloc.free(name);
        const sub_path = try std.fmt.allocPrint(alloc, ".ssh/{s}", .{name});
        defer alloc.free(sub_path);
        const body = try std.fmt.allocPrint(alloc, "Host inc-{d}\n", .{index});
        defer alloc.free(body);
        try tmp.dir.writeFile(.{ .sub_path = sub_path, .data = body });
        const line = try std.fmt.allocPrint(alloc, "Include {s}\n", .{name});
        defer alloc.free(line);
        try root.appendSlice(alloc, line);
    }
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/config", .data = root.items });
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    const hosts = try loadFromHome(alloc, home);
    defer deinitHosts(alloc, hosts);
    try testing.expectEqual(max_include_files, hosts.len);
}

test "ssh config bounds include opens away from the caller" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "include.conf", .data = "Host bounded\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "include.conf");
    defer alloc.free(path);

    const contents = (try readIncludeFileBounded(
        alloc,
        path,
        std.time.ns_per_s,
        readFile,
    )).?;
    defer alloc.free(contents);
    try testing.expectEqualStrings("Host bounded\n", contents);

    const slowRead = struct {
        fn run(worker_alloc: Allocator, ignored_path: []const u8) ![]u8 {
            _ = ignored_path;
            std.Thread.sleep(25 * std.time.ns_per_ms);
            return try worker_alloc.dupe(u8, "late");
        }
    }.run;
    try testing.expect((try readIncludeFileBounded(
        alloc,
        path,
        std.time.ns_per_ms,
        slowRead,
    )) == null);

    const wait_started = std.time.nanoTimestamp();
    while (include_read_in_progress.load(.acquire)) {
        if (std.time.nanoTimestamp() - wait_started > std.time.ns_per_s) {
            return error.TestUnexpectedResult;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "ssh config missing unreadable and oversized roots produce empty lists" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var missing = testing.tmpDir(.{});
    defer missing.cleanup();
    const missing_home = try missing.dir.realpathAlloc(alloc, ".");
    defer alloc.free(missing_home);
    const missing_hosts = try loadFromHome(alloc, missing_home);
    defer deinitHosts(alloc, missing_hosts);
    try testing.expectEqual(@as(usize, 0), missing_hosts.len);

    var unreadable = testing.tmpDir(.{});
    defer unreadable.cleanup();
    try unreadable.dir.makePath(".ssh/config");
    const unreadable_home = try unreadable.dir.realpathAlloc(alloc, ".");
    defer alloc.free(unreadable_home);
    const unreadable_hosts = try loadFromHome(alloc, unreadable_home);
    defer deinitHosts(alloc, unreadable_hosts);
    try testing.expectEqual(@as(usize, 0), unreadable_hosts.len);

    var oversized = testing.tmpDir(.{});
    defer oversized.cleanup();
    try oversized.dir.makePath(".ssh");
    const data = try alloc.alloc(u8, max_file_size + 1);
    defer alloc.free(data);
    @memset(data, '#');
    try oversized.dir.writeFile(.{ .sub_path = ".ssh/config", .data = data });
    const oversized_home = try oversized.dir.realpathAlloc(alloc, ".");
    defer alloc.free(oversized_home);
    const oversized_hosts = try loadFromHome(alloc, oversized_home);
    defer deinitHosts(alloc, oversized_hosts);
    try testing.expectEqual(@as(usize, 0), oversized_hosts.len);
}
