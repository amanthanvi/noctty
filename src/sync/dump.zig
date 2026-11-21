//! The dump of the runtime thread-role layer's pairs (PLAN.md §2.7 RQ12,
//! §19.3): one file per process, opened at the process's first pair in the
//! directory `NOCTTY_THREAD_ROLE_DUMP` names, as
//! `<dir>\<exe stem>-<pid>-<start>.pairs`, with each new pair appended at
//! once by one unbuffered `WriteFile` at the end of the file (the
//! end-of-file offset, which `WriteFile` documents as `FILE_APPEND_DATA`'s
//! append). A process that panics, crashes or is killed keeps every line it
//! wrote: nothing is buffered in the process. Without the variable nothing
//! is written. `recorder.zig` decides what is new; this file only writes.
//!
//! A pair it fails to write must not leave a dump that reads as complete:
//! a valid prefix with a pair missing passes the compare (stone round 3's
//! Sol M2: `tools\role_compare3.py` exited 0 on a header and its first
//! pair). So `append` says whether the pair is in the dump (the recorder
//! then keeps it unwritten, to be tried again), and the first failure marks
//! the dump failed: it overwrites the header's first byte, `#`, with `!` in
//! place, which needs no disk space, so the mark lands even where a full
//! disk stopped the pair, then appends `! append-failed win32=<error>` if
//! it can. A marked dump has no header `parseHeader` or a compare reads
//! (the symboliser reads it with `parseFailedHeader` and writes it as
//! `problem=append_failed`), so no collector passes it. A mark that cannot
//! be written panics, since the dump would read as complete. A failure of
//! the process dump is also logged as an error, which fails the running
//! test in the test exe.
//!
//! The dump is raw: it holds return addresses, not names. The compare reads
//! names (`<file>:<bare symbol> <role>`, `tools\role_compare3.py`), so a
//! symboliser (1A.2's WP4) maps each address through the image the dump's
//! header identifies, after checking the PDB's GUID and age against it, and
//! writes the compare's format. The raw format, `format=raw-1`, one LF-ended
//! line each:
//!
//!     # kind=<test-exe|child|gui|cli> pid=<decimal> start=<decimal FILETIME>
//!       format=raw-1 exe=<name> base=0x<16 hex> size=0x<8 hex>
//!       pdb_guid=<GUID|none> pdb_age=<decimal> pdb=<name|none>
//!     0x<16 hex return address> <acquire> <role>
//!     ! append-failed win32=<decimal>
//!
//! (the header is one line; it is wrapped here; a failed dump's header
//! begins `! kind=`, and it may hold the `!` line). The header begins as the
//! compare's dump header does (`# kind= pid= start=`), so a symboliser keeps
//! its first three fields. `start` is the process creation time from
//! `GetProcessTimes`, in 100 ns units since 1601 UTC, the value a launcher
//! joins on (PID and start time). `base` and `size` are the image's load
//! address and `SizeOfImage`: the image-relative call site is the address
//! minus `base` minus one. `pdb_guid` (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`,
//! the GUID's canonical text) and `pdb_age` are the image's CodeView `RSDS`
//! record, which a PDB must match; `pdb` and `exe` are file names only, never
//! a directory. `<acquire>` is `StateMutex`'s acquire (`lock`,
//! `lock_uncancelable`, `demand`, `try_lock`), `<role>` the role as the
//! reviewed table writes it (`ui`, `worker:<name>`). In `exe`, `pdb` and a
//! role, a byte outside `!`..`~`, and `\`, is written `\xNN`, so a line splits
//! on single spaces.
//!
//! The dump's directory comes from the environment, so it is screened before
//! anything opens it: a drive-absolute path (`X:\`), never a share, a device
//! or a relative path, with no stream. The file is created new
//! (`CREATE_NEW`): an existing file is never truncated or appended to, and a
//! process whose name is taken writes nothing. The handle is not inheritable,
//! so no child process holds it. A failed open is logged once with its
//! reason and the Win32 error, never the path (AGENTS.md "Logging").
//!
//! Opening runs on whichever thread records first, possibly the pty reader,
//! so its path, name and header buffers are static, behind one lock, and no
//! `std.fs` path conversion runs (each costs several hundred KiB of stack in
//! Zig 0.15.2: conpty.md, 2026-10-31 SURFACE-STACK).

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const thread_role = @import("thread_role.zig");
const Acquire = @import("state_mutex.zig").Acquire;

const Role = thread_role.Role;
const log = std.log.scoped(.thread_role);

/// The variable that names the process dump's directory.
pub const env_var = "NOCTTY_THREAD_ROLE_DUMP";
pub const env_var_w = std.unicode.utf8ToUtf16LeStringLiteral(env_var);

/// The raw format's name, in each header.
pub const format_name = "raw-1";
/// A dump file's extension.
pub const extension = ".pairs";

/// What a process is, as the compare's groups and launch rows name it.
pub const ProcessKind = enum {
    test_exe,
    child,
    gui,
    cli,

    /// This build's process: the test exe or the app. An isolated child
    /// says so through `recorder.setProcessKind` before its first pair.
    pub const default: ProcessKind = if (builtin.is_test) .test_exe else .gui;

    pub fn text(self: ProcessKind) []const u8 {
        return switch (self) {
            .test_exe => "test-exe",
            .child => "child",
            .gui => "gui",
            .cli => "cli",
        };
    }

    pub fn parse(value: []const u8) ?ProcessKind {
        inline for (comptime std.enums.values(ProcessKind)) |kind| {
            if (std.mem.eql(u8, value, kind.text())) return kind;
        }
        return null;
    }
};

/// Where a dump goes.
pub const Target = union(enum) {
    /// The directory the named environment variable holds, read at the first
    /// pair: the process dump's, `env_var`.
    environment: [:0]const u16,
    /// This directory: a test's dump.
    directory: [:0]const u16,
    /// Nowhere.
    none,
};

/// Why a dump writes nothing.
pub const Off = enum {
    /// The variable is unset or empty, or the target is `.none`.
    unset,
    /// The directory is not a drive-absolute path, or names a stream.
    not_drive_absolute,
    /// The directory and the dump's name do not fit the path buffer.
    too_long,
    /// A file of the dump's name exists; it is left as it is.
    exists,
    /// `CreateFileW` failed (`Dump.win32_error`).
    create_failed,
    /// The header could not be written (`Dump.win32_error`).
    header_failed,
    /// The image holding this code could not be identified.
    no_module,
};

/// One process's dump (or a test's). Any thread may append; the first
/// append opens it, and a test's `close` waits for appends in flight.
pub const Dump = struct {
    target: Target,
    /// The header's kind; set before the first append (`setKind`).
    kind: ProcessKind = .default,
    state: std.atomic.Value(State) = .init(.closed),
    /// Valid once `state` is `.open`.
    handle: ?windows.HANDLE = null,
    /// Why it writes nothing, once `state` is `.off`.
    off: ?Off = null,
    /// The Win32 error of a failed create or header write.
    win32_error: u32 = 0,
    /// Appends that may be using `handle`: `close` waits for none.
    appending: std.atomic.Value(u32) = .init(0),
    /// Pairs the open dump failed to write; the first marks it failed.
    lost: std.atomic.Value(u32) = .init(0),
    /// Set once the failure mark is on disk; a later failure waits for it.
    marked: std.atomic.Value(bool) = .init(false),
    /// The Win32 error of the first pair it failed to write.
    append_error: u32 = 0,
    /// A test's writer fault (`Fault`); nothing outside the test exe.
    fault: if (builtin.is_test) ?*Fault else void = if (builtin.is_test) null else {},

    const State = enum(u8) { closed, open, off };

    /// Appends one pair, opening the dump first if this is the first.
    /// False only when the dump is open and the pair is not in it: the
    /// write failed, and the dump is marked failed. A dump that writes
    /// nothing (no directory, off, closed) has nothing to keep: true.
    pub fn append(self: *Dump, site: usize, role: Role, acquire: Acquire) bool {
        // Counted before it reads the state, so a `close` that turns the
        // dump off either is seen here or sees this append (both seq_cst).
        _ = self.appending.fetchAdd(1, .seq_cst);
        defer _ = self.appending.fetchSub(1, .release);
        const handle = self.opened() orelse return true;
        var buf: [pair_line_max]u8 = undefined;
        const line = formatPair(&buf, site, role, acquire);
        const failed = if (self.injected(.pair)) injected_error else writeAt(handle, line, end_of_file);
        const err = failed orelse return true;
        self.markFailed(handle, err);
        return false;
    }

    /// How many pairs this dump failed to write.
    pub fn failedAppends(self: *const Dump) u32 {
        return self.lost.load(.acquire);
    }

    /// Marks the dump failed at its first lost pair: the header's `#`
    /// becomes `!` in place (no disk space needed), then the `!` line, if
    /// it can be appended. A later failure waits until the mark is on disk,
    /// so no thread goes on (and perhaps panics) while the dump on disk
    /// still reads as complete.
    fn markFailed(self: *Dump, handle: windows.HANDLE, err: u32) void {
        @branchHint(.cold);
        if (self.lost.fetchAdd(1, .acq_rel) != 0) {
            var spins: u32 = 0;
            while (!self.marked.load(.acquire)) {
                spins +%= 1;
                if (spins % 64 == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
            }
            return;
        }
        self.append_error = err;
        // A dump that cannot even be marked would read as complete without
        // the pair: the process panics, so the run ends abnormally, which
        // fails it (the suite's step, an isolated parent, an app harness that
        // reads the layer's text; APP-ROLE-PANIC-EXIT-01).
        const mark_failed = if (self.injected(.mark)) injected_error else writeAt(handle, &.{failed_mark}, 0);
        if (mark_failed) |mark_err| panicUnmarked(err, mark_err);
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{c} append-failed win32={d}\n", .{ failed_mark, err }) catch unreachable;
        if (!self.injected(.marker)) _ = writeAt(handle, line, end_of_file);
        self.marked.store(true, .release);
        if (self.target == .environment) {
            log.err("thread-role layer: the pairs dump failed to write a pair (Win32 error {d}); " ++
                "it is marked failed, and no compare passes it", .{err});
        }
    }

    /// Whether a test's fault fails this write.
    fn injected(self: *Dump, what: enum { pair, mark, marker }) bool {
        if (!builtin.is_test) return false;
        const fault = self.fault orelse return false;
        return switch (what) {
            .pair => fault.pairs.fetchAdd(1, .acq_rel) >= fault.pairs_before,
            .mark => fault.mark_fails,
            .marker => fault.marker_fails,
        };
    }

    /// Sets the header's kind. It fails once the dump has been opened or
    /// found off, that is after the first pair.
    pub fn setKind(self: *Dump, kind: ProcessKind) error{AlreadyDecided}!void {
        open_lock.lock();
        defer open_lock.unlock();
        if (self.state.load(.acquire) != .closed) return error.AlreadyDecided;
        self.kind = kind;
    }

    /// Whether the dump is open (it has written its header).
    pub fn isOpen(self: *const Dump) bool {
        return self.state.load(.acquire) == .open;
    }

    /// Closes a test's dump: an append that starts after it writes nothing,
    /// and one already writing finishes before the handle closes, so no
    /// append uses a handle value Windows may have given another file. The
    /// process dump stays open until the process ends.
    pub fn close(self: *Dump) void {
        {
            open_lock.lock();
            defer open_lock.unlock();
            if (self.state.load(.seq_cst) != .open) return;
            self.off = .unset;
            self.state.store(.off, .seq_cst);
        }
        // Outside the lock: an append that found the dump closed (before
        // its first pair) may be waiting for it, counted.
        var spins: u32 = 0;
        while (self.appending.load(.seq_cst) != 0) {
            spins +%= 1;
            if (spins % 64 == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
        windows.CloseHandle(self.handle.?);
        self.handle = null;
    }

    fn opened(self: *Dump) ?windows.HANDLE {
        return switch (self.state.load(.seq_cst)) {
            .open => self.handle.?,
            .off => null,
            .closed => self.openSlow(),
        };
    }

    fn openSlow(self: *Dump) ?windows.HANDLE {
        @branchHint(.cold);
        var dir_len: usize = 0;
        const handle = handle: {
            open_lock.lock();
            defer open_lock.unlock();
            switch (self.state.load(.acquire)) {
                .open => return self.handle.?,
                .off => return null,
                .closed => {},
            }
            const result = self.create(&dir_len);
            if (result) |h| {
                self.handle = h;
                self.state.store(.open, .release);
            } else {
                self.state.store(.off, .release);
            }
            break :handle result;
        };
        // Logged after the lock, and only for the process dump: a test reads
        // `off` itself. An unset variable is the normal case. A set one that
        // cannot be used leaves no file to mark, and a run's other processes
        // may still meet its group, so it is an error, which fails the
        // running test in the test exe.
        if (handle == null and self.target == .environment and self.off.? != .unset) {
            log.err(
                "thread-role layer: the pairs dump is off ({s}, Win32 error {d}; " ++
                    "its directory is {d} UTF-16 units); this process writes no pairs",
                .{ @tagName(self.off.?), self.win32_error, dir_len },
            );
        }
        return handle;
    }

    /// Opens the dump and writes its header, under `open_lock`.
    fn create(self: *Dump, dir_len_out: *usize) ?windows.HANDLE {
        const dir_len: usize = switch (self.target) {
            .none => return self.fail(.unset, 0),
            .directory => |dir| len: {
                if (dir.len >= path_buf.len) return self.fail(.too_long, 0);
                @memcpy(path_buf[0..dir.len], dir);
                break :len dir.len;
            },
            .environment => |name| len: {
                const n = GetEnvironmentVariableW(name.ptr, &path_buf, path_buf.len);
                if (n == 0) return self.fail(.unset, 0);
                if (n >= path_buf.len) return self.fail(.too_long, 0);
                break :len n;
            },
        };
        dir_len_out.* = dir_len;
        const dir = path_buf[0..dir_len];
        if (!isDriveAbsolute(dir)) return self.fail(.not_drive_absolute, 0);

        const module = selfModule() orelse return self.fail(.no_module, 0);
        const exe = moduleFileName(module.base) orelse return self.fail(.no_module, 0);
        const id = processIdentity();

        // <dir>\<exe stem>-<pid>-<start>.pairs, NUL-terminated.
        var len = dir_len;
        if (dir[dir_len - 1] != '\\' and dir[dir_len - 1] != '/') {
            len = appendUnits(&path_buf, len, &.{'\\'}) orelse return self.fail(.too_long, 0);
        }
        len = appendUnits(&path_buf, len, exeStem(exe)) orelse return self.fail(.too_long, 0);
        var name_buf: [64]u8 = undefined;
        const tail = std.fmt.bufPrint(&name_buf, "-{d}-{d}" ++ extension, .{ id.pid, id.start }) catch unreachable;
        for (tail) |byte| {
            len = appendUnits(&path_buf, len, &.{byte}) orelse return self.fail(.too_long, 0);
        }
        if (len >= path_buf.len) return self.fail(.too_long, 0);
        path_buf[len] = 0;

        // Write access, not append access alone: a failure overwrites the
        // header's first byte (`markFailed`); every line is written at the
        // end-of-file offset.
        const handle = windows.kernel32.CreateFileW(
            path_buf[0..len :0].ptr,
            windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_DELETE,
            null, // not inheritable
            windows.CREATE_NEW,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) {
            const err = windows.GetLastError();
            return self.fail(if (err == .FILE_EXISTS) .exists else .create_failed, @intFromEnum(err));
        }

        const header = formatHeader(&header_buf, .{
            .kind = self.kind,
            .pid = id.pid,
            .start = id.start,
            .base = module.base,
            .size = module.size,
            .pdb = module.pdb,
        }, exe);
        if (writeAt(handle, header, end_of_file)) |err| {
            windows.CloseHandle(handle);
            return self.fail(.header_failed, err);
        }
        return handle;
    }

    fn fail(self: *Dump, why: Off, win32_error: u32) ?windows.HANDLE {
        self.off = why;
        self.win32_error = win32_error;
        return null;
    }
};

/// Serialises every dump's open, and guards the static buffers below.
var open_lock: std.Thread.Mutex = .{};
var path_buf: [32768]u16 = undefined;
var module_buf: [32768]u16 = undefined;
var header_buf: [header_max]u8 = undefined;

const header_max = 8192;
/// At most a line's bytes; a longer role is cut, and the line fails to
/// parse or to match a table row.
pub const pair_line_max = 256;

/// The first byte of a failed dump's header, and of the line it appends
/// (`Dump.markFailed`).
pub const failed_mark: u8 = '!';

/// The end-of-file offset: `WriteFile` with both halves of the offset
/// 0xFFFFFFFF writes at the end of the file, which it documents as the same
/// as a `FILE_APPEND_DATA` handle's write, so lines from many threads land
/// whole, one after another.
const end_of_file: u64 = std.math.maxInt(u64);

/// The failed pair write a test injects (`Fault`): a full disk's.
const injected_error: ?u32 = @intFromEnum(windows.Win32Error.DISK_FULL);

/// A test's writer fault: the first `pairs_before` pairs are written and
/// every later one fails as a full disk fails it, writing nothing; with
/// `marker_fails` the `!` line fails too, and with `mark_fails` so does the
/// in-place mark, the double failure, after which the process panics
/// (`panicUnmarked`), so only an isolated child sets it.
pub const Fault = struct {
    pairs_before: u32,
    marker_fails: bool = false,
    mark_fails: bool = false,
    pairs: std.atomic.Value(u32) = .init(0),
};

/// Writes `bytes` with one `WriteFile` at `offset` (`end_of_file` to
/// append). The Win32 error, or null; a short write is `WRITE_FAULT`.
fn writeAt(handle: windows.HANDLE, bytes: []const u8, offset: u64) ?u32 {
    var written: windows.DWORD = 0;
    const len: windows.DWORD = @intCast(bytes.len);
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME = .{
        .Offset = @truncate(offset),
        .OffsetHigh = @truncate(offset >> 32),
    };
    // The handle is synchronous: the call returns once the write is done.
    if (windows.kernel32.WriteFile(handle, bytes.ptr, len, &written, &overlapped) == 0) {
        return @intFromEnum(windows.GetLastError());
    }
    if (written != len) return @intFromEnum(windows.Win32Error.WRITE_FAULT);
    return null;
}

fn panicUnmarked(append_error: u32, mark_error: u32) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: the pairs dump failed to write a pair (Win32 error {d}) and to " ++
            "mark itself failed (Win32 error {d}); it would read as complete without the pair",
        .{ append_error, mark_error },
    );
}

fn appendUnits(buf: []u16, len: usize, units: []const u16) ?usize {
    if (len + units.len >= buf.len) return null;
    for (units, 0..) |unit, i| buf[len + i] = unit;
    return len + units.len;
}

/// A directory the dump may be opened in: `X:\...` or `X:/...`, with no
/// `:` after the drive (a stream). A share (`\\server\share`), a device or
/// NT path (`\\.\`, `\\?\`, `\??\`) and a relative path are refused before
/// anything opens them (launch-and-paths.md, 2026-10-06; settings.md's
/// "drive-absolute, not a network or device path, no stream").
pub fn isDriveAbsolute(dir: []const u16) bool {
    if (dir.len < 3) return false;
    const drive = dir[0];
    if (!((drive >= 'A' and drive <= 'Z') or (drive >= 'a' and drive <= 'z'))) return false;
    if (dir[1] != ':' or (dir[2] != '\\' and dir[2] != '/')) return false;
    return std.mem.indexOfScalar(u16, dir[2..], ':') == null;
}

/// The file name of a path (after its last `\` or `/`).
fn baseName(comptime T: type, path: []const T) []const T {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '\\' or path[i - 1] == '/') break;
    }
    return path[i..];
}

/// An exe's file name without a trailing `.exe` (any case).
fn exeStem(name: []const u16) []const u16 {
    if (name.len > 4) {
        const ext = name[name.len - 4 ..];
        if (ext[0] == '.' and lower(ext[1]) == 'e' and lower(ext[2]) == 'x' and lower(ext[3]) == 'e') {
            return name[0 .. name.len - 4];
        }
    }
    return name;
}

fn lower(unit: u16) u16 {
    return if (unit >= 'A' and unit <= 'Z') unit + ('a' - 'A') else unit;
}

/// The file name of the image at `base`, in `module_buf` (under
/// `open_lock`).
fn moduleFileName(base: usize) ?[]const u16 {
    const n = windows.kernel32.GetModuleFileNameW(@ptrFromInt(base), &module_buf, module_buf.len);
    if (n == 0 or n >= module_buf.len) return null;
    return baseName(u16, module_buf[0..n]);
}

/// A process as a launcher and the compare's join name it.
pub const Identity = struct {
    pid: u32,
    /// The creation time, 100 ns units since 1601 UTC (0 if unreadable).
    start: u64,
};

pub fn processIdentity() Identity {
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    const start: u64 = if (GetProcessTimes(windows.GetCurrentProcess(), &creation, &exit, &kernel, &user) != 0)
        @as(u64, creation.dwHighDateTime) << 32 | creation.dwLowDateTime
    else
        0;
    return .{ .pid = windows.GetCurrentProcessId(), .start = start };
}

/// The PDB an image names in its CodeView `RSDS` record.
pub const Pdb = struct {
    guid: [16]u8,
    age: u32,
    /// The PDB's file name (the record's path after its last separator).
    name: []const u8,
};

/// An image as a symboliser needs it: where it is loaded, its size and its
/// PDB.
pub const Module = struct {
    base: usize,
    size: u32,
    pdb: ?Pdb,
};

/// The image holding this code: the exe whose `StateMutex` sites the
/// recorder sees. Null if Windows cannot name it or its headers do not
/// parse.
pub fn selfModule() ?Module {
    var handle: ?windows.HMODULE = null;
    if (GetModuleHandleExW(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrCast(&selfModule),
        &handle,
    ) == 0) return null;
    const base = @intFromPtr(handle orelse return null);
    // The headers are in the image's first page, which is always mapped.
    const head: [*]const u8 = @ptrFromInt(base);
    const size = sizeOfImage(head[0..0x1000]) catch return null;
    const image = parseImage(head[0..size]) catch return null;
    return .{ .base = base, .size = image.size, .pdb = image.pdb };
}

/// What `parseImage` reads.
pub const Image = struct {
    size: u32,
    pdb: ?Pdb,
};

pub const ImageError = error{BadImage};

// PE offsets (the PE format; `std.coff` reads the same).
const dos_lfanew = 0x3c;
const coff_header_len = 20;
const opt_size_of_image = 56;
const pe32_magic = 0x10b;
const pe32_plus_magic = 0x20b;
const debug_directory_index = 6;
const debug_entry_len = 28;
const debug_entry_type = 12;
const debug_entry_raw_data_size = 16;
const debug_entry_raw_data_rva = 20;
const debug_type_codeview = 2;
const rsds_header_len = 24;

fn readU16(image: []const u8, at: usize) ImageError!u16 {
    if (at > image.len or image.len - at < 2) return error.BadImage;
    return std.mem.readInt(u16, image[at..][0..2], .little);
}

fn readU32(image: []const u8, at: usize) ImageError!u32 {
    if (at > image.len or image.len - at < 4) return error.BadImage;
    return std.mem.readInt(u32, image[at..][0..4], .little);
}

/// The offset of the optional header, past the DOS stub and the PE
/// signature.
fn optionalHeader(image: []const u8) ImageError!usize {
    if (image.len < 0x40 or !std.mem.eql(u8, image[0..2], "MZ")) return error.BadImage;
    const nt = try readU32(image, dos_lfanew);
    if (nt > image.len or image.len - nt < 4 or !std.mem.eql(u8, image[nt..][0..4], "PE\x00\x00")) {
        return error.BadImage;
    }
    return @as(usize, nt) + 4 + coff_header_len;
}

/// `SizeOfImage` from a loaded image's headers.
pub fn sizeOfImage(head: []const u8) ImageError!u32 {
    const opt = try optionalHeader(head);
    return try readU32(head, opt + opt_size_of_image);
}

/// Reads a loaded image (sections at their RVAs, as the loader maps them):
/// its size and the PDB its CodeView record names. `pdb` is null for an
/// image with no CodeView `RSDS` record (a stripped build has no PDB:
/// build-release-ci.md, 2026-10-16). Every read is bounded by `image` and
/// `SizeOfImage`.
pub fn parseImage(image_in: []const u8) ImageError!Image {
    const opt = try optionalHeader(image_in);
    const size = try readU32(image_in, opt + opt_size_of_image);
    const image = image_in[0..@min(image_in.len, size)];
    const coff = opt - coff_header_len;
    const opt_len = try readU16(image, coff + 16);
    const dirs: usize, const count_at: usize = switch (try readU16(image, opt)) {
        pe32_magic => .{ 96, 92 },
        pe32_plus_magic => .{ 112, 108 },
        else => return error.BadImage,
    };
    const no_pdb: Image = .{ .size = size, .pdb = null };
    if (opt_len < dirs + 8 * (debug_directory_index + 1)) return no_pdb;
    if (try readU32(image, opt + count_at) <= debug_directory_index) return no_pdb;
    const debug_rva = try readU32(image, opt + dirs + 8 * debug_directory_index);
    const debug_len = try readU32(image, opt + dirs + 8 * debug_directory_index + 4);
    if (debug_rva == 0 or debug_len == 0) return no_pdb;

    var i: usize = 0;
    while (i < debug_len / debug_entry_len) : (i += 1) {
        const entry = @as(usize, debug_rva) + i * debug_entry_len;
        if (try readU32(image, entry + debug_entry_type) != debug_type_codeview) continue;
        const raw_len = try readU32(image, entry + debug_entry_raw_data_size);
        const raw_rva = try readU32(image, entry + debug_entry_raw_data_rva);
        if (raw_rva > image.len or image.len - raw_rva < raw_len or raw_len < rsds_header_len) {
            return error.BadImage;
        }
        const raw = image[raw_rva..][0..raw_len];
        if (!std.mem.eql(u8, raw[0..4], "RSDS")) return no_pdb;
        const path = raw[rsds_header_len..];
        const end = std.mem.indexOfScalar(u8, path, 0) orelse return error.BadImage;
        return .{ .size = size, .pdb = .{
            .guid = raw[4..20].*,
            .age = std.mem.readInt(u32, raw[20..24], .little),
            .name = baseName(u8, path[0..end]),
        } };
    }
    return no_pdb;
}

/// A GUID's canonical text, `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`: its
/// first three fields little-endian, as `GUID` stores them (the text DbgHelp
/// and the symbol tools print).
pub fn formatGuid(guid: [16]u8) [36]u8 {
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{
        std.mem.readInt(u32, guid[0..4], .little),
        std.mem.readInt(u16, guid[4..6], .little),
        std.mem.readInt(u16, guid[6..8], .little),
        guid[8],
        guid[9],
        guid[10],
        guid[11],
        guid[12],
        guid[13],
        guid[14],
        guid[15],
    }) catch unreachable;
    return out;
}

pub fn parseGuid(text: []const u8) error{BadGuid}![16]u8 {
    if (text.len != 36 or text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') {
        return error.BadGuid;
    }
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        hex[n] = c;
        n += 1;
    }
    var raw: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, &hex) catch return error.BadGuid;
    var guid: [16]u8 = undefined;
    // The text's first three fields are big-endian numbers; GUID stores
    // them little-endian.
    std.mem.writeInt(u32, guid[0..4], std.mem.readInt(u32, raw[0..4], .big), .little);
    std.mem.writeInt(u16, guid[4..6], std.mem.readInt(u16, raw[4..6], .big), .little);
    std.mem.writeInt(u16, guid[6..8], std.mem.readInt(u16, raw[6..8], .big), .little);
    @memcpy(guid[8..16], raw[8..16]);
    return guid;
}

/// A dump's header, as written and as `parseHeader` reads it back. `exe`
/// and a parsed `pdb.name` are the escaped text (`unescape` decodes it).
pub const Header = struct {
    kind: ProcessKind,
    pid: u32,
    start: u64,
    base: u64,
    size: u32,
    pdb: ?Pdb,
    exe: []const u8 = "",
};

fn formatHeader(buf: []u8, header: Header, exe: []const u16) []const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    writeHeaderFields(&w, header, exe) catch {};
    // A header cut short is still one line; it fails to parse.
    const len = w.end;
    buf[len] = '\n';
    return buf[0 .. len + 1];
}

fn writeHeaderFields(w: *std.Io.Writer, header: Header, exe: []const u16) std.Io.Writer.Error!void {
    try w.print("# kind={s} pid={d} start={d} format=" ++ format_name ++ " exe=", .{
        header.kind.text(),
        header.pid,
        header.start,
    });
    try writeEscapedWtf16(w, exe);
    try w.print(" base=0x{x:0>16} size=0x{x:0>8}", .{ header.base, header.size });
    if (header.pdb) |pdb| {
        try w.print(" pdb_guid={s} pdb_age={d} pdb=", .{ &formatGuid(pdb.guid), pdb.age });
        try writeEscaped(w, pdb.name);
    } else {
        try w.writeAll(" pdb_guid=none pdb_age=0 pdb=none");
    }
}

/// One pair's line, LF-ended, in `buf`.
pub fn formatPair(buf: *[pair_line_max]u8, site: usize, role: Role, acquire: Acquire) []const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.print("0x{x:0>16} {s} ", .{ site, @tagName(acquire) }) catch unreachable;
    writeRole(&w, role) catch {};
    const len = w.end;
    buf[len] = '\n';
    return buf[0 .. len + 1];
}

/// A role as the reviewed table writes it (`thread_role.Role.format`),
/// with a worker's name escaped.
fn writeRole(w: *std.Io.Writer, role: Role) std.Io.Writer.Error!void {
    switch (role) {
        .worker => |name| {
            try w.writeAll("worker:");
            try writeEscaped(w, name);
        },
        else => try w.writeAll(@tagName(role)),
    }
}

fn plain(byte: u8) bool {
    return byte >= '!' and byte <= '~' and byte != '\\';
}

fn writeEscaped(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    for (bytes) |byte| {
        if (plain(byte)) try w.writeByte(byte) else try w.print("\\x{x:0>2}", .{byte});
    }
}

/// UTF-16 (WTF-16) as escaped WTF-8.
fn writeEscapedWtf16(w: *std.Io.Writer, units: []const u16) std.Io.Writer.Error!void {
    var it = std.unicode.Wtf16LeIterator.init(units);
    while (it.nextCodepoint()) |cp| {
        var bytes: [4]u8 = undefined;
        const n = std.unicode.wtf8Encode(cp, &bytes) catch unreachable;
        try writeEscaped(w, bytes[0..n]);
    }
}

/// Decodes text written by `writeEscaped` into `out`.
pub fn unescape(out: []u8, text: []const u8) error{ BadEscape, NoSpace }![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (n == out.len) return error.NoSpace;
        if (text[i] != '\\') {
            if (!plain(text[i])) return error.BadEscape;
            out[n] = text[i];
            i += 1;
            continue;
        }
        if (text.len - i < 4 or text[i + 1] != 'x') return error.BadEscape;
        out[n] = std.fmt.parseInt(u8, text[i + 2 .. i + 4], 16) catch return error.BadEscape;
        i += 4;
    }
    return out[0..n];
}

pub const ParseError = error{BadLine};

fn trimLine(line: []const u8) []const u8 {
    var end = line.len;
    if (end > 0 and line[end - 1] == '\n') end -= 1;
    if (end > 0 and line[end - 1] == '\r') end -= 1;
    return line[0..end];
}

fn field(it: *std.mem.SplitIterator(u8, .scalar), comptime key: []const u8) ParseError![]const u8 {
    const token = it.next() orelse return error.BadLine;
    if (!std.mem.startsWith(u8, token, key ++ "=")) return error.BadLine;
    return token[key.len + 1 ..];
}

fn hexField(value: []const u8, comptime T: type, digits: usize) ParseError!T {
    if (value.len != 2 + digits or !std.mem.startsWith(u8, value, "0x")) return error.BadLine;
    return std.fmt.parseInt(T, value[2..], 16) catch error.BadLine;
}

fn decimal(comptime T: type, value: []const u8) ParseError!T {
    if (value.len == 0 or value[0] == '+') return error.BadLine;
    return std.fmt.parseInt(T, value, 10) catch error.BadLine;
}

/// Reads a raw dump's header line (with or without its LF): every field, in
/// order, and nothing more.
pub fn parseHeader(line: []const u8) ParseError!Header {
    return parseHeaderMarked(line, "#");
}

/// Reads the header of a dump whose writer failed (`Dump.markFailed`): the
/// same fields, after `!` in place of `#`. `parseHeader` refuses it, so a
/// reader that does not ask for it takes the dump for one with no header.
pub fn parseFailedHeader(line: []const u8) ParseError!Header {
    return parseHeaderMarked(line, &.{failed_mark});
}

/// Whether a line after the header is a failed dump's own (`! ...`), not a
/// pair.
pub fn isFailedLine(line: []const u8) bool {
    return line.len > 0 and line[0] == failed_mark;
}

fn parseHeaderMarked(line: []const u8, mark: []const u8) ParseError!Header {
    var it = std.mem.splitScalar(u8, trimLine(line), ' ');
    if (!std.mem.eql(u8, it.next() orelse "", mark)) return error.BadLine;
    const kind = ProcessKind.parse(try field(&it, "kind")) orelse return error.BadLine;
    const pid = try decimal(u32, try field(&it, "pid"));
    const start = try decimal(u64, try field(&it, "start"));
    if (!std.mem.eql(u8, try field(&it, "format"), format_name)) return error.BadLine;
    const exe = try field(&it, "exe");
    const base = try hexField(try field(&it, "base"), u64, 16);
    const size = try hexField(try field(&it, "size"), u32, 8);
    const guid_text = try field(&it, "pdb_guid");
    const age = try decimal(u32, try field(&it, "pdb_age"));
    const pdb_name = try field(&it, "pdb");
    if (it.next() != null or exe.len == 0 or pdb_name.len == 0) return error.BadLine;
    const pdb: ?Pdb = if (std.mem.eql(u8, guid_text, "none")) none: {
        if (age != 0 or !std.mem.eql(u8, pdb_name, "none")) return error.BadLine;
        break :none null;
    } else .{
        .guid = parseGuid(guid_text) catch return error.BadLine,
        .age = age,
        .name = pdb_name,
    };
    return .{ .kind = kind, .pid = pid, .start = start, .exe = exe, .base = base, .size = size, .pdb = pdb };
}

/// One raw pair line, as `parsePair` reads it.
pub const PairLine = struct {
    site: u64,
    acquire: Acquire,
    /// The role's escaped text (`ui`, `worker:<name>`).
    role: []const u8,
};

/// Reads a raw dump's pair line (with or without its LF).
pub fn parsePair(line: []const u8) ParseError!PairLine {
    var it = std.mem.splitScalar(u8, trimLine(line), ' ');
    const site = try hexField(it.next() orelse return error.BadLine, u64, 16);
    const acquire = std.meta.stringToEnum(Acquire, it.next() orelse return error.BadLine) orelse
        return error.BadLine;
    const role = it.next() orelse return error.BadLine;
    if (it.next() != null or role.len == 0) return error.BadLine;
    return .{ .site = site, .acquire = acquire, .role = role };
}

const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 0x2;
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x4;

extern "kernel32" fn GetModuleHandleExW(
    flags: u32,
    name: ?*const anyopaque,
    module: *?windows.HMODULE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetProcessTimes(
    process: windows.HANDLE,
    creation: *windows.FILETIME,
    exit: *windows.FILETIME,
    kernel: *windows.FILETIME,
    user: *windows.FILETIME,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetEnvironmentVariableW(
    name: [*:0]const u16,
    buffer: [*]u16,
    size: windows.DWORD,
) callconv(.winapi) windows.DWORD;

const testing = std.testing;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "a directory must be drive-absolute, with no stream" {
    try testing.expect(isDriveAbsolute(L("C:\\scratch\\dump")));
    try testing.expect(isDriveAbsolute(L("h:/scratch/dump")));
    try testing.expect(isDriveAbsolute(L("D:\\")));
    try testing.expect(!isDriveAbsolute(L("relative\\dump")));
    try testing.expect(!isDriveAbsolute(L("C:relative")));
    try testing.expect(!isDriveAbsolute(L("\\\\server\\share\\dump")));
    try testing.expect(!isDriveAbsolute(L("//server/share/dump")));
    try testing.expect(!isDriveAbsolute(L("\\\\?\\C:\\dump")));
    try testing.expect(!isDriveAbsolute(L("\\\\.\\pipe\\dump")));
    try testing.expect(!isDriveAbsolute(L("\\??\\C:\\dump")));
    try testing.expect(!isDriveAbsolute(L("\\dump")));
    try testing.expect(!isDriveAbsolute(L("C:\\dump:stream")));
    try testing.expect(!isDriveAbsolute(L("1:\\dump")));
    try testing.expect(!isDriveAbsolute(L("C:")));
}

test "an exe's stem drops .exe in any case and nothing else" {
    try testing.expectEqualSlices(u16, L("ghostty-test"), exeStem(L("ghostty-test.exe")));
    try testing.expectEqualSlices(u16, L("noctty"), exeStem(L("noctty.EXE")));
    try testing.expectEqualSlices(u16, L("noctty.com"), exeStem(L("noctty.com")));
    try testing.expectEqualSlices(u16, L(".exe"), exeStem(L(".exe")));
    try testing.expectEqualSlices(u16, L("a.exe"), baseName(u16, L("C:\\x\\a.exe")));
    try testing.expectEqualSlices(u8, "b.pdb", baseName(u8, "C:/x\\y/b.pdb"));
    try testing.expectEqualSlices(u8, "c.pdb", baseName(u8, "c.pdb"));
}

test "a GUID's text round-trips, its first three fields little-endian" {
    const guid = [16]u8{ 0x78, 0x56, 0x34, 0x12, 0x34, 0x12, 0x78, 0x56, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78 };
    const text = formatGuid(guid);
    try testing.expectEqualStrings("12345678-1234-5678-9ABC-DEF012345678", &text);
    try testing.expectEqual(guid, try parseGuid(&text));
    try testing.expectEqual(guid, try parseGuid("12345678-1234-5678-9abc-def012345678"));
    try testing.expectError(error.BadGuid, parseGuid("12345678-1234-5678-9ABC-DEF01234567"));
    try testing.expectError(error.BadGuid, parseGuid("12345678+1234-5678-9ABC-DEF012345678"));
    try testing.expectError(error.BadGuid, parseGuid("1234567G-1234-5678-9ABC-DEF012345678"));
}

test "a header round-trips, with and without a PDB" {
    const guid = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var buf: [header_max]u8 = undefined;
    const written: Header = .{
        .kind = .child,
        .pid = 4321,
        .start = 134081234567890123,
        .base = 0x7ff6a1b20000,
        .size = 0x2a4f000,
        .pdb = .{ .guid = guid, .age = 3, .name = "ghostty test.pdb" },
    };
    const line = formatHeader(&buf, written, L("ghostty-test.exe"));
    try testing.expectEqualStrings(
        "# kind=child pid=4321 start=134081234567890123 format=raw-1 exe=ghostty-test.exe " ++
            "base=0x00007ff6a1b20000 size=0x02a4f000 pdb_guid=04030201-0605-0807-090A-0B0C0D0E0F10 " ++
            "pdb_age=3 pdb=ghostty\\x20test.pdb\n",
        line,
    );
    const read = try parseHeader(line);
    try testing.expectEqual(written.kind, read.kind);
    try testing.expectEqual(written.pid, read.pid);
    try testing.expectEqual(written.start, read.start);
    try testing.expectEqual(written.base, read.base);
    try testing.expectEqual(written.size, read.size);
    try testing.expectEqualStrings("ghostty-test.exe", read.exe);
    try testing.expectEqual(guid, read.pdb.?.guid);
    try testing.expectEqual(@as(u32, 3), read.pdb.?.age);
    var name: [64]u8 = undefined;
    try testing.expectEqualStrings("ghostty test.pdb", try unescape(&name, read.pdb.?.name));

    // The compare's own header regex reads the first three fields.
    try testing.expect(std.mem.startsWith(u8, line, "# kind=child pid=4321 start=134081234567890123 "));

    var none = written;
    none.kind = .test_exe;
    none.pdb = null;
    const line2 = formatHeader(&buf, none, L("n\u{e9}.exe"));
    try testing.expect(std.mem.endsWith(u8, line2, " pdb_guid=none pdb_age=0 pdb=none\n"));
    try testing.expect(std.mem.indexOf(u8, line2, " exe=n\\xc3\\xa9.exe ") != null);
    const read2 = try parseHeader(line2);
    try testing.expectEqual(ProcessKind.test_exe, read2.kind);
    try testing.expectEqual(@as(?Pdb, null), read2.pdb);
    try testing.expectEqualStrings("n\u{e9}.exe", try unescape(&name, read2.exe));
}

test "a malformed header fails to parse" {
    const good = "# kind=gui pid=1 start=2 format=raw-1 exe=a.exe base=0x0000000000000001 " ++
        "size=0x00000002 pdb_guid=none pdb_age=0 pdb=none";
    _ = try parseHeader(good);
    const bad = [_][]const u8{
        "",
        "# kind=gui pid=1 start=2",
        "# kind=gui pid=1 start=2 format=raw-2 exe=a.exe base=0x0000000000000001 " ++
            "size=0x00000002 pdb_guid=none pdb_age=0 pdb=none",
        "# kind=window pid=1 start=2 format=raw-1 exe=a.exe base=0x0000000000000001 " ++
            "size=0x00000002 pdb_guid=none pdb_age=0 pdb=none",
        "# pid=1 kind=gui start=2 format=raw-1 exe=a.exe base=0x0000000000000001 " ++
            "size=0x00000002 pdb_guid=none pdb_age=0 pdb=none",
        "# kind=gui pid=-1 start=2 format=raw-1 exe=a.exe base=0x0000000000000001 " ++
            "size=0x00000002 pdb_guid=none pdb_age=0 pdb=none",
        "# kind=gui pid=1 start=2 format=raw-1 exe=a.exe base=0x1 " ++
            "size=0x00000002 pdb_guid=none pdb_age=0 pdb=none",
        "# kind=gui pid=1 start=2 format=raw-1 exe=a.exe base=0x0000000000000001 " ++
            "size=0x00000002 pdb_guid=none pdb_age=1 pdb=none",
        good ++ " extra=1",
        good ++ " ",
        "#  kind=gui pid=1 start=2 format=raw-1 exe=a.exe base=0x0000000000000001 " ++
            "size=0x00000002 pdb_guid=none pdb_age=0 pdb=none",
    };
    for (bad) |line| try testing.expectError(error.BadLine, parseHeader(line));
}

test "a pair line round-trips, a worker's name escaped" {
    var buf: [pair_line_max]u8 = undefined;
    const ui = formatPair(&buf, 0x7ff6a1c3d2e1, .ui, .lock);
    try testing.expectEqualStrings("0x00007ff6a1c3d2e1 lock ui\n", ui);
    const read = try parsePair(ui);
    try testing.expectEqual(@as(u64, 0x7ff6a1c3d2e1), read.site);
    try testing.expectEqual(Acquire.lock, read.acquire);
    try testing.expectEqualStrings("ui", read.role);

    const worker = formatPair(&buf, 0x10, .{ .worker = "update-check" }, .demand);
    try testing.expectEqualStrings("0x0000000000000010 demand worker:update-check\n", worker);

    const odd = formatPair(&buf, 0x20, .{ .worker = "a b\\c\u{e9}" }, .try_lock);
    try testing.expectEqualStrings("0x0000000000000020 try_lock worker:a\\x20b\\x5cc\\xc3\\xa9\n", odd);
    const read_odd = try parsePair(odd);
    var name: [32]u8 = undefined;
    try testing.expectEqualStrings("worker:a b\\c\u{e9}", try unescape(&name, read_odd.role));

    for ([_]Role{ .none, .renderer, .termio, .reader, .search, .test_support }) |role| {
        const line = formatPair(&buf, 1, role, .lock_uncancelable);
        const back = try parsePair(line);
        try testing.expectEqual(Acquire.lock_uncancelable, back.acquire);
        try testing.expectEqualStrings(@tagName(role), back.role);
    }

    // A name too long for a line is cut: still one line, the role wrong.
    const long = "n" ** (pair_line_max * 2);
    const cut = formatPair(&buf, 1, .{ .worker = long }, .lock);
    try testing.expectEqual(pair_line_max, cut.len);
    try testing.expectEqual('\n', cut[cut.len - 1]);
    try testing.expect(std.mem.indexOfScalar(u8, cut[0 .. cut.len - 1], '\n') == null);

    try testing.expectError(error.BadLine, parsePair("0x10 lock ui"));
    try testing.expectError(error.BadLine, parsePair("0x0000000000000010 unlock ui"));
    try testing.expectError(error.BadLine, parsePair("0x0000000000000010 lock"));
    try testing.expectError(error.BadLine, parsePair("0x0000000000000010 lock ui extra"));
    try testing.expectError(error.BadLine, parsePair("src/a.zig:f ui"));
    try testing.expectError(error.BadEscape, unescape(&name, "a\\x2"));
    try testing.expectError(error.BadEscape, unescape(&name, "a b"));
}

/// A minimal loaded PE32+ image with a CodeView record, for `parseImage`.
fn testImage(buf: *[0x400]u8, rsds: []const u8) void {
    @memset(buf, 0);
    buf[0] = 'M';
    buf[1] = 'Z';
    std.mem.writeInt(u32, buf[dos_lfanew..][0..4], 0x80, .little);
    @memcpy(buf[0x80..0x84], "PE\x00\x00");
    const coff = 0x84;
    std.mem.writeInt(u16, buf[coff..][0..2], 0x8664, .little);
    std.mem.writeInt(u16, buf[coff + 16 ..][0..2], 240, .little);
    const opt = coff + coff_header_len;
    std.mem.writeInt(u16, buf[opt..][0..2], pe32_plus_magic, .little);
    std.mem.writeInt(u32, buf[opt + opt_size_of_image ..][0..4], buf.len, .little);
    std.mem.writeInt(u32, buf[opt + 108 ..][0..4], 16, .little);
    const dir = opt + 112 + 8 * debug_directory_index;
    std.mem.writeInt(u32, buf[dir..][0..4], 0x200, .little);
    std.mem.writeInt(u32, buf[dir + 4 ..][0..4], 2 * debug_entry_len, .little);
    // A first entry of another type, then the CodeView one.
    std.mem.writeInt(u32, buf[0x200 + debug_entry_type ..][0..4], 16, .little);
    const cv = 0x200 + debug_entry_len;
    std.mem.writeInt(u32, buf[cv + debug_entry_type ..][0..4], debug_type_codeview, .little);
    std.mem.writeInt(u32, buf[cv + debug_entry_raw_data_size ..][0..4], @intCast(rsds.len), .little);
    std.mem.writeInt(u32, buf[cv + debug_entry_raw_data_rva ..][0..4], 0x300, .little);
    @memcpy(buf[0x300..][0..rsds.len], rsds);
}

test "parseImage reads SizeOfImage and the CodeView record at the PE offsets" {
    const guid = [16]u8{ 0xa, 0xb, 0xc, 0xd, 0xe, 0xf, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x10 };
    const rsds = "RSDS" ++ guid ++ "\x07\x00\x00\x00" ++ "C:\\build\\out\\name.pdb\x00";
    var buf: [0x400]u8 = undefined;
    testImage(&buf, rsds);
    const image = try parseImage(&buf);
    try testing.expectEqual(@as(u32, 0x400), image.size);
    try testing.expectEqual(guid, image.pdb.?.guid);
    try testing.expectEqual(@as(u32, 7), image.pdb.?.age);
    try testing.expectEqualStrings("name.pdb", image.pdb.?.name);
    try testing.expectEqual(@as(u32, 0x400), try sizeOfImage(&buf));

    // Another CodeView format has no PDB identity.
    testImage(&buf, "NB10" ++ guid ++ "\x07\x00\x00\x00x\x00");
    try testing.expectEqual(@as(?Pdb, null), (try parseImage(&buf)).pdb);

    // A path with no NUL, a record past the image, a bad signature.
    testImage(&buf, rsds[0 .. rsds.len - 1]);
    try testing.expectError(error.BadImage, parseImage(&buf));
    testImage(&buf, rsds);
    std.mem.writeInt(u32, buf[0x200 + debug_entry_len + debug_entry_raw_data_rva ..][0..4], 0x3f0, .little);
    try testing.expectError(error.BadImage, parseImage(&buf));
    testImage(&buf, rsds);
    buf[0x81] = 'X';
    try testing.expectError(error.BadImage, parseImage(&buf));
    testImage(&buf, rsds);
    try testing.expectError(error.BadImage, parseImage(buf[0..0x30]));

    // No debug directory: no PDB.
    testImage(&buf, rsds);
    @memset(buf[0x84 + coff_header_len + 112 + 8 * debug_directory_index ..][0..8], 0);
    try testing.expectEqual(@as(?Pdb, null), (try parseImage(&buf)).pdb);
}

test "selfModule names this image and its PDB as std.coff reads them" {
    const module = selfModule() orelse return error.TestUnexpectedResult;
    // The sync code is linked into the exe.
    try testing.expectEqual(@intFromPtr(windows.peb().ImageBaseAddress), module.base);
    const here = @intFromPtr(&selfModule);
    try testing.expect(here >= module.base and here < module.base + module.size);

    const image: [*]const u8 = @ptrFromInt(module.base);
    var coff = try std.coff.Coff.init(image[0..module.size], true);
    if (try coff.getPdbPath()) |path| {
        const pdb = module.pdb orelse return error.TestUnexpectedResult;
        try testing.expectEqual(coff.guid, pdb.guid);
        try testing.expectEqual(coff.age, pdb.age);
        try testing.expectEqualStrings(baseName(u8, path), pdb.name);
        try testing.expect(std.ascii.endsWithIgnoreCase(pdb.name, ".pdb"));
    } else {
        try testing.expectEqual(@as(?Pdb, null), module.pdb);
    }
}

test "processIdentity is this process's ID and creation time" {
    const id = processIdentity();
    try testing.expectEqual(windows.GetCurrentProcessId(), id.pid);
    // Created after 2020-01-01 (FILETIME 132223104000000000) and not in the
    // future (1970 is FILETIME 116444736000000000).
    const now: u64 = @intCast(@divFloor(std.time.nanoTimestamp(), 100) + 116444736000000000);
    try testing.expect(id.start > 132223104000000000);
    try testing.expect(id.start <= now);
    try testing.expectEqual(id, processIdentity());
}

test "a dump with no target, or an unset variable, writes nothing" {
    var none: Dump = .{ .target = .none };
    try testing.expect(none.append(0x10, .ui, .lock));
    try testing.expect(!none.isOpen());
    try testing.expectEqual(Off.unset, none.off.?);
    try testing.expectError(error.AlreadyDecided, none.setKind(.child));

    // A variable no process sets.
    var unset: Dump = .{ .target = .{ .environment = L("NOCTTY_THREAD_ROLE_DUMP_UNSET_BY_TEST_7c1e") } };
    try unset.setKind(.child);
    try testing.expect(unset.append(0x10, .ui, .lock));
    try testing.expect(!unset.isOpen());
    try testing.expectEqual(Off.unset, unset.off.?);

    var relative: Dump = .{ .target = .{ .directory = L("relative\\dump") } };
    try testing.expect(relative.append(0x10, .ui, .lock));
    try testing.expectEqual(Off.not_drive_absolute, relative.off.?);
    var share: Dump = .{ .target = .{ .directory = L("\\\\server\\share") } };
    try testing.expect(share.append(0x10, .ui, .lock));
    try testing.expectEqual(Off.not_drive_absolute, share.off.?);
}

/// A test's directory as a dump target, and the one dump file in it.
pub const TestDir = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u16,

    pub fn init() !TestDir {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const utf8 = try tmp.dir.realpathAlloc(testing.allocator, ".");
        defer testing.allocator.free(utf8);
        return .{ .tmp = tmp, .path = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, utf8) };
    }

    pub fn deinit(self: *TestDir) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    /// The names of the files in it.
    pub fn count(self: *TestDir) !usize {
        var n: usize = 0;
        var it = self.tmp.dir.iterate();
        while (try it.next()) |_| n += 1;
        return n;
    }

    /// The one dump's contents, read through a handle of its own.
    pub fn read(self: *TestDir) ![]u8 {
        var it = self.tmp.dir.iterate();
        const entry = (try it.next()) orelse return error.NoDump;
        if (try it.next() != null) return error.TwoFiles;
        if (!std.mem.endsWith(u8, entry.name, extension)) return error.NotADump;
        return self.tmp.dir.readFileAlloc(testing.allocator, entry.name, 1 << 20);
    }

    pub fn name(self: *TestDir, buf: []u8) ![]const u8 {
        var it = self.tmp.dir.iterate();
        const entry = (try it.next()) orelse return error.NoDump;
        if (entry.name.len > buf.len) return error.NoSpace;
        @memcpy(buf[0..entry.name.len], entry.name);
        return buf[0..entry.name.len];
    }
};

test "a dump opens at its first pair, appends each at once and is readable while open" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var d: Dump = .{ .target = .{ .directory = dir.path } };
    defer d.close();
    try d.setKind(.child);
    try testing.expectEqual(@as(usize, 0), try dir.count());

    try testing.expect(d.append(0x7ff600001000, .ui, .lock));
    try testing.expect(d.isOpen());
    try testing.expectError(error.AlreadyDecided, d.setKind(.gui));

    // Read through another handle while the dump is open, as a compare
    // reads a dump a hung or crashed process left: nothing is buffered.
    const first = try dir.read();
    defer testing.allocator.free(first);
    var lines = std.mem.splitScalar(u8, first, '\n');
    const header = try parseHeader(lines.next().?);
    try testing.expectEqualStrings("0x00007ff600001000 lock ui", lines.next().?);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());

    const id = processIdentity();
    const module = selfModule().?;
    try testing.expectEqual(ProcessKind.child, header.kind);
    try testing.expectEqual(id.pid, header.pid);
    try testing.expectEqual(id.start, header.start);
    try testing.expectEqual(@as(u64, module.base), header.base);
    try testing.expectEqual(module.size, header.size);
    if (module.pdb) |pdb| {
        try testing.expectEqual(pdb.guid, header.pdb.?.guid);
        try testing.expectEqual(pdb.age, header.pdb.?.age);
    }
    try testing.expect(std.ascii.endsWithIgnoreCase(header.exe, ".exe"));

    // The file's name is <exe stem>-<pid>-<start>.pairs.
    var name_buf: [256]u8 = undefined;
    const file_name = try dir.name(&name_buf);
    var tail_buf: [64]u8 = undefined;
    const tail = try std.fmt.bufPrint(&tail_buf, "-{d}-{d}.pairs", .{ id.pid, id.start });
    try testing.expect(std.mem.endsWith(u8, file_name, tail));
    try testing.expectEqualStrings(header.exe[0 .. header.exe.len - 4], file_name[0 .. file_name.len - tail.len]);

    try testing.expect(d.append(0x7ff600002000, .{ .worker = "update-check" }, .demand));
    const second = try dir.read();
    defer testing.allocator.free(second);
    try testing.expect(std.mem.startsWith(u8, second, first));
    try testing.expectEqualStrings("0x00007ff600002000 demand worker:update-check\n", second[first.len..]);
}

test "a dump never truncates or appends to an existing file, and it reads back after its close" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var a: Dump = .{ .target = .{ .directory = dir.path } };
    defer a.close();
    try testing.expect(a.append(0x1000, .termio, .lock));
    try testing.expect(a.append(0x2000, .reader, .try_lock));
    a.close();
    try testing.expect(!a.isOpen());
    const before = try dir.read();
    defer testing.allocator.free(before);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, before, "\n"));

    // A second dump of this process in that directory has the same name.
    var b: Dump = .{ .target = .{ .directory = dir.path } };
    try testing.expect(b.append(0x3000, .search, .lock));
    try testing.expect(!b.isOpen());
    try testing.expectEqual(Off.exists, b.off.?);
    try testing.expectEqual(@intFromEnum(windows.Win32Error.FILE_EXISTS), b.win32_error);

    const after = try dir.read();
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    var lines = std.mem.splitScalar(u8, after, '\n');
    _ = try parseHeader(lines.next().?);
    try testing.expectEqual(@as(u64, 0x1000), (try parsePair(lines.next().?)).site);
    try testing.expectEqual(@as(u64, 0x2000), (try parsePair(lines.next().?)).site);
}

test "a close while threads append leaves whole lines, and nothing is written after it" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var d: Dump = .{ .target = .{ .directory = dir.path } };
    defer d.close();
    try testing.expect(d.append(0x1000, .ui, .lock));

    const Appender = struct {
        fn run(dump: *Dump, t: usize, go: *std.atomic.Value(bool)) void {
            while (!go.load(.acquire)) std.atomic.spinLoopHint();
            for (0..200) |i| _ = dump.append(0x10000 + t * 0x1000 + i, .termio, .lock);
        }
    };
    var go: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, t| thread.* = try std.Thread.spawn(.{}, Appender.run, .{ &d, t, &go });
    go.store(true, .release);
    d.close();
    for (threads) |thread| thread.join();
    try testing.expect(!d.isOpen());
    try testing.expect(d.append(0x2000, .ui, .lock));

    const text = try dir.read();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = try parseHeader(lines.next().?);
    try testing.expectEqual(@as(u64, 0x1000), (try parsePair(lines.next().?)).site);
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const pair = try parsePair(line);
        try testing.expect(pair.site != 0x2000);
    }
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "a pair the dump fails to write marks it failed in place, and no reader takes it for complete" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var fault: Fault = .{ .pairs_before = 1 };
    var d: Dump = .{ .target = .{ .directory = dir.path }, .kind = .child, .fault = &fault };
    defer d.close();
    try testing.expect(d.append(0x1000, .ui, .lock));
    const before = try dir.read();
    defer testing.allocator.free(before);
    _ = try parseHeader(std.mem.sliceTo(before, '\n'));

    // A full disk: nothing of the pair is written, and append says so.
    try testing.expect(!d.append(0x2000, .termio, .lock));
    try testing.expectEqual(@as(u32, 1), d.failedAppends());
    try testing.expectEqual(@intFromEnum(windows.Win32Error.DISK_FULL), d.append_error);
    const after = try dir.read();
    defer testing.allocator.free(after);
    // The header's first byte is `!`, overwritten in place; the rest is as
    // it was, and the failure's line follows.
    try testing.expectEqual(@as(u8, '!'), after[0]);
    try testing.expectEqualStrings(before[1..], after[1..before.len]);
    try testing.expectEqualStrings("! append-failed win32=112\n", after[before.len..]);
    var lines = std.mem.splitScalar(u8, after, '\n');
    const first = lines.next().?;
    try testing.expectError(error.BadLine, parseHeader(first));
    const header = try parseFailedHeader(first);
    try testing.expectEqual(ProcessKind.child, header.kind);
    try testing.expectEqual(processIdentity().pid, header.pid);
    try testing.expectEqual(@as(u64, 0x1000), (try parsePair(lines.next().?)).site);
    const mark = lines.next().?;
    try testing.expect(isFailedLine(mark));
    try testing.expectError(error.BadLine, parsePair(mark));
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectError(error.BadLine, parseFailedHeader(std.mem.sliceTo(before, '\n')));

    // A second failure is counted; the mark is written once.
    try testing.expect(!d.append(0x3000, .ui, .lock));
    try testing.expectEqual(@as(u32, 2), d.failedAppends());
    const again = try dir.read();
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(after, again);

    // Writes that work again append after the mark; the dump stays failed.
    fault.pairs_before = std.math.maxInt(u32);
    try testing.expect(d.append(0x2000, .termio, .lock));
    const last = try dir.read();
    defer testing.allocator.free(last);
    try testing.expect(std.mem.startsWith(u8, last, after));
    try testing.expectEqualStrings("0x0000000000002000 lock termio\n", last[after.len..]);
}

test "a full disk that also stops the failure's line still leaves the header marked" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var fault: Fault = .{ .pairs_before = 1, .marker_fails = true };
    var d: Dump = .{ .target = .{ .directory = dir.path }, .fault = &fault };
    defer d.close();
    try testing.expect(d.append(0x1000, .ui, .lock));
    const before = try dir.read();
    defer testing.allocator.free(before);
    try testing.expect(!d.append(0x2000, .termio, .lock));
    const after = try dir.read();
    defer testing.allocator.free(after);
    try testing.expectEqual(before.len, after.len);
    try testing.expectEqual(@as(u8, '!'), after[0]);
    try testing.expectEqualStrings(before[1..], after[1..]);
    try testing.expectError(error.BadLine, parseHeader(std.mem.sliceTo(after, '\n')));
    _ = try parseFailedHeader(std.mem.sliceTo(after, '\n'));
}

test "isolated: a full disk that stops both a pair and the in-place mark panics with the layer's text" {
    // Stone round 4, Sol's Medium 2: when the mark cannot be written either,
    // the dump on disk is a valid header and an allowed prefix that every
    // collector would pass, so the process panics and the run ends
    // abnormally. The child writes into the directory its parent made
    // (`Dumps.own`), and the parent reads what survived. A build without
    // the layer (lib-vt's tests) has no isolated children: the skip comes
    // first, so isolated.zig is never analysed there.
    if (thread_role.layer == .off) return error.SkipZigTest;
    const isolated = @import("isolated.zig");
    if (isolated.inChild()) {
        const dir_utf8 = try std.process.getEnvVarOwned(testing.allocator, env_var);
        defer testing.allocator.free(dir_utf8);
        const dir = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, dir_utf8);
        defer testing.allocator.free(dir);
        var fault: Fault = .{ .pairs_before = 1, .mark_fails = true };
        var d: Dump = .{ .target = .{ .directory = dir }, .kind = .child, .fault = &fault };
        defer d.close();
        try testing.expect(d.append(0x1000, .ui, .lock));
        _ = d.append(0x2000, .termio, .lock);
        return error.TheDoubleFailureDidNotPanic;
    }
    var child = try isolated.run(@src(), .own);
    defer child.deinit();
    try isolated.expectChildPanicked(&child, @src(), "thread-role layer: the pairs dump failed to write a pair " ++
        "(Win32 error 112) and to mark itself failed (Win32 error 112); it would read as complete without the pair");
    // What survived reads as a complete dump with the allowed pair only:
    // the panic, not the file, is what fails the run.
    const text = try child.dir.?.read();
    defer testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = try parseHeader(lines.next().?);
    try testing.expectEqual(@as(u64, 0x1000), (try parsePair(lines.next().?)).site);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "threads that lose pairs at once wait for one mark" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var fault: Fault = .{ .pairs_before = 0 };
    var d: Dump = .{ .target = .{ .directory = dir.path }, .fault = &fault };
    defer d.close();

    const Loser = struct {
        fn run(dump: *Dump, t: usize, go: *std.atomic.Value(bool), written: *std.atomic.Value(u32)) void {
            while (!go.load(.acquire)) std.atomic.spinLoopHint();
            for (0..8) |i| {
                if (dump.append(0x10000 + t * 0x100 + i, .reader, .lock)) _ = written.fetchAdd(1, .monotonic);
                // Each failed append returns only once the mark is on disk.
                if (!dump.marked.load(.acquire)) _ = written.fetchAdd(1000, .monotonic);
            }
        }
    };
    var go: std.atomic.Value(bool) = .init(false);
    var written: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, t| thread.* = try std.Thread.spawn(.{}, Loser.run, .{ &d, t, &go, &written });
    go.store(true, .release);
    for (threads) |thread| thread.join();
    try testing.expectEqual(@as(u32, 0), written.load(.monotonic));
    try testing.expectEqual(@as(u32, 32), d.failedAppends());

    const text = try dir.read();
    defer testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = try parseFailedHeader(lines.next().?);
    try testing.expectEqualStrings("! append-failed win32=112", lines.next().?);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "a missing directory leaves the dump off with its Win32 error" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const missing = try std.mem.concatWithSentinel(testing.allocator, u16, &.{ dir.path, L("\\missing") }, 0);
    defer testing.allocator.free(missing);
    var d: Dump = .{ .target = .{ .directory = missing } };
    try testing.expect(d.append(0x1000, .ui, .lock));
    try testing.expectEqual(Off.create_failed, d.off.?);
    try testing.expectEqual(@intFromEnum(windows.Win32Error.PATH_NOT_FOUND), d.win32_error);
    try testing.expectEqual(@as(usize, 0), try dir.count());
}
