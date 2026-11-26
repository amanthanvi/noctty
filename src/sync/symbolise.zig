//! The symboliser of the runtime thread-role layer's dumps (PLAN.md §2.7
//! RQ13, §19.1, §19.3; the lead's 1A.2 decision 9): it maps each raw pair
//! (`dump.zig`'s `format=raw-1`, a return address) to the compare's function
//! key, `<file>:<bare symbol>`, through DbgHelp's `SymFromAddrW` and
//! `SymGetLineFromAddrW64` against the image's PDB, after checking that the
//! dump, the image and the PDB DbgHelp loaded carry one GUID and age.
//!
//! It is a test tool, kept out of the product build: only the test exe
//! reaches it, through an isolated parent's in-process compare
//! (`isolated.zig`) and through the test exe's symbolise mode
//! (`runFromEnvironment`), which writes the dumps `tools\role_compare3.py`
//! reads for the Debug suite, test 13 and 1A.6's composite. DbgHelp is
//! loaded from System32 when a session first opens, never imported.
//!
//! What DbgHelp names, measured on Zig 0.15.2 Debug against `std.debug` on
//! the same addresses (a scratch probe with the wrapper's inline-method
//! shape): the same bytes for a plain function, a struct method, a nested
//! container's function, both instantiations of a generic method (each
//! bare), a comptime-parameter instantiation (`name__anon_N`, which the
//! compare strips), a test block (`test.<name>`, a non-ASCII name included)
//! and a site in an `inline fn` (its caller, as §19.1 says of 0.15.2); and the
//! line table gives the acquiring function's file and line, not the
//! wrapper's, for the call `StateMutex`'s inline method makes.
//!
//! The symbolised format, one LF-ended line each:
//!
//!     # kind=<kind> pid=<pid> start=<start> format=sym-1 exe=<name>
//!       pdb_guid=<GUID> pdb_age=<age>[ problem=<problem>]
//!     <file relative to the source root, with />:<symbol> <role>
//!
//! (the header is one line). Its first three fields are the raw header's,
//! which the compare joins on. A pair that cannot be named is written
//! `?<why>:0x<address> <role>`, a key with no file, which fails the compare
//! as UNQUALIFIED-KEY, and so is every pair of a dump whose identity does
//! not match (`problem=`): a bad dump can never pass. A dump whose writer
//! failed to write a pair (its raw header begins `!`: `dump.Dump.append`)
//! is `problem=append_failed`, every pair of it written so, and its first
//! line after the header is `lost_line`, `?append_failed:pairs-lost none`,
//! so it fails `tools\role_compare3.py` as UNQUALIFIED-KEY even when it
//! holds no pair, or only pairs the table holds; `compare.zig` fails a
//! `problem=` header as BAD-DUMP.

const std = @import("std");
const win32_sys = @import("../apprt/win32/sys.zig");
const win32_types = @import("../apprt/win32_types.zig");
const builtin = @import("builtin");
const windows = std.os.windows;
const dump = @import("dump.zig");

const Allocator = std.mem.Allocator;

/// The symbolised format's name, in each header.
pub const format_name = "sym-1";

/// Whether this build's tests may check a recorded function's name (PLAN.md
/// §2.7 RQ16): on the architectures the attribution probe has run on. 1A.2
/// ran probe-r14 once on the hosted ARM64 runner (the lead's 1A.2 decision
/// 12), and every site attributed there as on x64, on both compilers and
/// in both modes (test-harnesses.md, 2026-11-21 ARM64-PROBE-01). The one
/// architecture switch for every test that checks a name: this file's
/// site-shape test reads it with each shape's own mode rule, and the
/// isolated parents through `names_checked`.
pub const names_attributed = switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => true,
    else => false,
};

/// Whether this build's isolated parents check a recorded function's name
/// (RQ16): where names are attributed, in Debug on 0.15.2, and in Debug and
/// ReleaseSafe from 0.17 on. 0.15.2's ReleaseSafe attributes only `noinline`
/// functions (§19.2), so there the parents check the panic and the role, and
/// a test left with nothing else to check, such as acceptance test 10's
/// site shapes, is skipped.
pub const names_checked = names_attributed and
    (builtin.mode == .Debug or builtin.zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) != .lt);

/// The symbolise mode's variables (`runFromEnvironment`): the raw dumps'
/// directory, the directory the symbolised ones are written to (it must
/// exist; a file is never overwritten), the directory holding each dump's
/// image beside its PDB (default: this exe's), and the source root keys
/// are relative to (default: this build's, `Session.sourceRoot`).
pub const raw_env = "NOCTTY_THREAD_ROLE_SYMBOLISE";
pub const out_env = "NOCTTY_THREAD_ROLE_SYMBOLISED";
pub const images_env = "NOCTTY_THREAD_ROLE_IMAGES";
pub const root_env = "NOCTTY_THREAD_ROLE_SOURCE_ROOT";

/// This file, relative to the source root: `Session.sourceRoot` finds the
/// root by naming one of its own addresses.
const own_path = "src\\sync\\symbolise.zig";

/// Why a dump, or one of its pairs, could not be named.
pub const Problem = enum {
    /// The raw header does not parse.
    bad_header,
    /// The dump or the image has no PDB identity (a stripped build).
    no_pdb,
    /// The dump's PDB GUID or age is not the image's.
    pdb_mismatch,
    /// DbgHelp did not load that PDB for the image.
    pdb_not_loaded,
    /// No image of the dump's exe name in the images directory, or one that
    /// cannot be read.
    no_image,
    /// The dump's writer failed to write a pair (its header's `!`): the
    /// pairs it holds are a prefix, and a lost one may be off the table.
    append_failed,
};

/// The line a dump whose writer failed gets after its header, whatever
/// pairs it holds: a key with no file, which no compare passes.
pub const lost_line = "?append_failed:pairs-lost none\n";

/// A raw dump's header: a complete dump's, or one whose writer failed
/// (`dump.parseFailedHeader`). Its line must end in LF: a header the
/// writer did not finish is no header (stone round 4, Sol's Medium 2).
fn readHeader(raw: []const u8) ?struct { header: dump.Header, failed: bool } {
    const end = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    const line = raw[0..end];
    if (dump.parseHeader(line)) |header| return .{ .header = header, .failed = false } else |_| {}
    if (dump.parseFailedHeader(line)) |header| return .{ .header = header, .failed = true } else |_| {}
    return null;
}

// DbgHelp, as `DbgHelp.h` declares it (inside `pshpack8.h`, which changes no
// x64 layout here; the sizes and offsets are pinned in a test).
const SymbolInfoW = extern struct {
    SizeOfStruct: u32,
    TypeIndex: u32,
    Reserved: [2]u64,
    Index: u32,
    Size: u32,
    ModBase: u64,
    Flags: u32,
    Value: u64,
    Address: u64,
    Register: u32,
    Scope: u32,
    Tag: u32,
    NameLen: u32,
    MaxNameLen: u32,
    Name: [1]u16,
};

const ImagehlpLineW64 = extern struct {
    SizeOfStruct: u32,
    Key: ?*anyopaque,
    LineNumber: u32,
    FileName: ?[*:0]const u16,
    Address: u64,
};

const ImagehlpModuleW64 = extern struct {
    SizeOfStruct: u32,
    BaseOfImage: u64,
    ImageSize: u32,
    TimeDateStamp: u32,
    CheckSum: u32,
    NumSyms: u32,
    SymType: u32,
    ModuleName: [32]u16,
    ImageName: [256]u16,
    LoadedImageName: [256]u16,
    LoadedPdbName: [256]u16,
    CVSig: u32,
    CVData: [780]u16,
    PdbSig: u32,
    PdbSig70: [16]u8,
    PdbAge: u32,
    PdbUnmatched: win32_types.BOOL,
    DbgUnmatched: win32_types.BOOL,
    LineNumbers: win32_types.BOOL,
    GlobalSymbols: win32_types.BOOL,
    TypeInfo: win32_types.BOOL,
    SourceIndexed: win32_types.BOOL,
    Publics: win32_types.BOOL,
    MachineType: u32,
    Reserved: u32,
};

const sym_pdb = 3;
const sym_dia = 7;

/// Lines on; no symbol server, no `_NT_SYMBOL_PATH`, no CodeView path (the
/// PDB is looked for beside the image only), an exact match only, no
/// public symbols (whose names are linkage names), no prompts.
const sym_options: u32 = 0x10 | // SYMOPT_LOAD_LINES
    0x80 | // SYMOPT_IGNORE_CVREC
    0x200 | // SYMOPT_FAIL_CRITICAL_ERRORS
    0x400 | // SYMOPT_EXACT_SYMBOLS
    0x1000 | // SYMOPT_IGNORE_NT_SYMPATH
    0x8000 | // SYMOPT_NO_PUBLICS
    0x80000 | // SYMOPT_NO_PROMPTS
    0x02000000; // SYMOPT_DISABLE_SYMSRV_AUTODETECT

const Api = struct {
    SymSetOptions: *const fn (options: u32) callconv(.winapi) u32,
    SymInitializeW: *const fn (process: windows.HANDLE, search_path: ?[*:0]const u16, invade: win32_types.BOOL) callconv(.winapi) win32_types.BOOL,
    SymCleanup: *const fn (process: windows.HANDLE) callconv(.winapi) win32_types.BOOL,
    SymLoadModuleExW: *const fn (
        process: windows.HANDLE,
        file: ?windows.HANDLE,
        image: ?[*:0]const u16,
        module: ?[*:0]const u16,
        base: u64,
        size: u32,
        data: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) u64,
    SymGetModuleInfoW64: *const fn (process: windows.HANDLE, address: u64, info: *ImagehlpModuleW64) callconv(.winapi) win32_types.BOOL,
    SymFromAddrW: *const fn (process: windows.HANDLE, address: u64, displacement: ?*u64, symbol: *SymbolInfoW) callconv(.winapi) win32_types.BOOL,
    SymGetLineFromAddrW64: *const fn (process: windows.HANDLE, address: u64, displacement: *u32, line: *ImagehlpLineW64) callconv(.winapi) win32_types.BOOL,
};

const LOAD_LIBRARY_AS_DATAFILE: u32 = 0x2;
const LOAD_LIBRARY_AS_IMAGE_RESOURCE: u32 = 0x20;
const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x800;

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?windows.HANDLE, flags: u32) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) win32_types.BOOL;

/// DbgHelp is single-threaded: one session at a time, held from `open` to
/// `close`.
var session_lock: std.Thread.Mutex = .{};
/// Loaded at the first session, kept for the process (under the lock).
var api: ?Api = null;
/// Its address names this file's DbgHelp sessions: `SymInitializeW` takes
/// any unique value when it does not invade a process.
var session_token: u8 = 0;

fn sessionHandle() windows.HANDLE {
    return @ptrCast(&session_token);
}

fn loadApi() error{NoDbgHelp}!*const Api {
    if (api) |*loaded| return loaded;
    const lib = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("dbghelp.dll"), null, LOAD_LIBRARY_SEARCH_SYSTEM32) orelse
        return error.NoDbgHelp;
    var fns: Api = undefined;
    inline for (@typeInfo(Api).@"struct".fields) |field| {
        const proc = GetProcAddress(lib, field.name) orelse return error.NoDbgHelp;
        // A function pointer is aligned 4 on aarch64 and 1 on x86_64, so only an
        // aarch64 build rejects the cast without the assertion (tabs-panes.md,
        // 2026-11-08 TEAROFF-01, review round 2).
        @field(fns, field.name) = @ptrCast(@alignCast(proc));
    }
    api = fns;
    return &api.?;
}

/// A function and its file, as DbgHelp names them (WTF-8).
pub const Location = struct {
    name: []u8,
    file: []u8,

    pub fn deinit(self: Location, a: Allocator) void {
        a.free(self.name);
        a.free(self.file);
    }
};

/// What DbgHelp loaded for an image.
pub const Loaded = struct {
    sym_type: u32,
    pdb_guid: [16]u8,
    pdb_age: u32,
    unmatched: bool,
    line_numbers: bool,

    /// Whether this is the PDB `pdb` names, matched, with lines.
    pub fn matches(self: Loaded, pdb: dump.Pdb) bool {
        return (self.sym_type == sym_pdb or self.sym_type == sym_dia) and !self.unmatched and
            self.line_numbers and std.mem.eql(u8, &self.pdb_guid, &pdb.guid) and self.pdb_age == pdb.age;
    }
};

/// One image loaded into DbgHelp at `base`. Only one session is open at a
/// time; `open` waits for the last to close.
pub const Session = struct {
    api: *const Api,
    base: u64,
    size: u32,

    pub const OpenError = error{ NoDbgHelp, SymInitializeFailed, LoadModuleFailed, OutOfMemory, NameTooLong };

    /// Loads `image` (its PDB beside it) at `base`, a virtual load: nothing
    /// of the image runs.
    pub fn open(a: Allocator, image: []const u16, base: u64, size: u32) OpenError!Session {
        const image_z = try a.dupeZ(u16, image);
        defer a.free(image_z);
        // The search path: the image's directory.
        const dir_len = dirLength(image) orelse return error.NameTooLong;
        const dir_z = try a.dupeZ(u16, image[0..dir_len]);
        defer a.free(dir_z);

        session_lock.lock();
        errdefer session_lock.unlock();
        const fns = try loadApi();
        _ = fns.SymSetOptions(sym_options);
        if (fns.SymInitializeW(sessionHandle(), dir_z.ptr, win32_types.FALSE) == 0) return error.SymInitializeFailed;
        errdefer _ = fns.SymCleanup(sessionHandle());
        if (fns.SymLoadModuleExW(sessionHandle(), null, image_z.ptr, null, base, size, null, 0) == 0) {
            return error.LoadModuleFailed;
        }
        return .{ .api = fns, .base = base, .size = size };
    }

    /// This process's own image, at its own base.
    pub fn openSelf(a: Allocator) (OpenError || error{NoModule})!Session {
        const module = dump.selfModule() orelse return error.NoModule;
        var buf: [32768]u16 = undefined;
        const n = win32_sys.GetModuleFileNameW(@ptrFromInt(module.base), &buf, buf.len);
        if (n == 0 or n >= buf.len) return error.NoModule;
        return open(a, buf[0..n], module.base, module.size);
    }

    pub fn close(self: *Session) void {
        _ = self.api.SymCleanup(sessionHandle());
        session_lock.unlock();
    }

    /// What DbgHelp loaded for the image.
    pub fn loaded(self: *const Session) ?Loaded {
        var info = std.mem.zeroes(ImagehlpModuleW64);
        info.SizeOfStruct = @sizeOf(ImagehlpModuleW64);
        if (self.api.SymGetModuleInfoW64(sessionHandle(), self.base, &info) == 0) return null;
        return .{
            .sym_type = info.SymType,
            .pdb_guid = info.PdbSig70,
            .pdb_age = info.PdbAge,
            .unmatched = info.PdbUnmatched != 0,
            .line_numbers = info.LineNumbers != 0,
        };
    }

    /// The function holding `address` and its source file, or null when
    /// DbgHelp names neither.
    pub fn locate(self: *const Session, a: Allocator, address: u64) Allocator.Error!?Location {
        const max_name = 2048;
        var buf: [@sizeOf(SymbolInfoW) + 2 * max_name]u8 align(@alignOf(SymbolInfoW)) = undefined;
        const symbol: *SymbolInfoW = @ptrCast(&buf);
        symbol.* = std.mem.zeroes(SymbolInfoW);
        symbol.SizeOfStruct = @sizeOf(SymbolInfoW);
        symbol.MaxNameLen = max_name;
        var displacement: u64 = 0;
        if (self.api.SymFromAddrW(sessionHandle(), address, &displacement, symbol) == 0) return null;
        const name_units: [*]const u16 = @ptrCast(&symbol.Name);
        const name = try std.unicode.wtf16LeToWtf8Alloc(a, name_units[0..@min(symbol.NameLen, max_name)]);
        errdefer a.free(name);

        var line = std.mem.zeroes(ImagehlpLineW64);
        line.SizeOfStruct = @sizeOf(ImagehlpLineW64);
        var line_displacement: u32 = 0;
        if (self.api.SymGetLineFromAddrW64(sessionHandle(), address, &line_displacement, &line) == 0) {
            a.free(name);
            return null;
        }
        const file_name = line.FileName orelse {
            a.free(name);
            return null;
        };
        const file = try std.unicode.wtf16LeToWtf8Alloc(a, std.mem.span(file_name));
        return .{ .name = name, .file = file };
    }

    /// The source root of this process's own build: the directory its
    /// PDB's path for this file sits under, with a trailing separator. The
    /// session must be `openSelf`'s.
    pub fn sourceRoot(self: *const Session, a: Allocator) (Allocator.Error || error{NoSourceRoot})![]u8 {
        // A function's own first instruction: its file whatever the mode inlines.
        const location = (try self.locate(a, @intFromPtr(&calibrationSite))) orelse return error.NoSourceRoot;
        defer location.deinit(a);
        const file = location.file;
        if (file.len <= own_path.len) return error.NoSourceRoot;
        const tail = file[file.len - own_path.len ..];
        for (tail, own_path) |got, want| {
            const g = if (got == '/') '\\' else std.ascii.toLower(got);
            if (g != std.ascii.toLower(want)) return error.NoSourceRoot;
        }
        return a.dupe(u8, file[0 .. file.len - own_path.len]);
    }
};

/// A function of this file, whose address `Session.sourceRoot` names.
noinline fn calibrationSite() usize {
    return @returnAddress();
}

/// The length of a path's directory part (before its last separator).
fn dirLength(path: []const u16) ?usize {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '\\' or path[i - 1] == '/') return if (i == 1) 1 else i - 1;
    }
    return null;
}

/// A source file as a key's file: relative to `root` (compared without
/// case, either separator) with `/`, or the whole path with `/` when it is
/// not under the root (which no table row names).
pub fn keyFile(a: Allocator, file: []const u8, root: []const u8) Allocator.Error![]u8 {
    const rest = if (underRoot(file, root)) file[root.len..] else file;
    const out = try a.dupe(u8, rest);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

fn underRoot(file: []const u8, root: []const u8) bool {
    if (root.len == 0 or file.len <= root.len) return false;
    for (file[0..root.len], root) |f, r| {
        const fc = if (f == '/') '\\' else std.ascii.toLower(f);
        const rc = if (r == '/') '\\' else std.ascii.toLower(r);
        if (fc != rc) return false;
    }
    return true;
}

/// A symbol's bytes in a key: a control byte (below 0x20, or DEL) as
/// `\xNN`, which no table row spells, so such a name fails closed (an
/// acquiring test needs a name without one: §2.7 RQ13).
fn writeName(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) try w.print("\\x{x:0>2}", .{byte}) else try w.writeByte(byte);
    }
}

/// One dump, symbolised.
pub const Result = struct {
    text: []u8,
    pairs: usize = 0,
    /// Pairs written as an unqualified key.
    unresolved: usize = 0,
    /// Why no pair could be named, if none could.
    problem: ?Problem = null,

    pub fn deinit(self: Result, a: Allocator) void {
        a.free(self.text);
    }
};

/// Symbolises a raw dump through `session`, which holds the dump's image:
/// `image_pdb` is that image's own CodeView record, `root` the source root
/// keys are relative to. A dump whose identity does not match keeps its
/// header (with `problem=`) and writes every pair unqualified.
pub fn symbolise(a: Allocator, raw: []const u8, session: *const Session, image_pdb: ?dump.Pdb, root: []const u8) Allocator.Error!Result {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var result: Result = .{ .text = undefined };
    write(a, &out.writer, raw, session, image_pdb, root, &result) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    result.text = try out.toOwnedSlice();
    return result;
}

fn write(
    a: Allocator,
    w: *std.Io.Writer,
    raw: []const u8,
    session: *const Session,
    image_pdb: ?dump.Pdb,
    root: []const u8,
    result: *Result,
) (std.Io.Writer.Error || Allocator.Error)!void {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.first();
    const read = readHeader(raw) orelse {
        // No header: the compare fails it as BAD-DUMP.
        result.problem = .bad_header;
        return;
    };
    const header = read.header;
    result.problem = problem: {
        if (read.failed) break :problem .append_failed;
        const dump_pdb = header.pdb orelse break :problem .no_pdb;
        const own = image_pdb orelse break :problem .no_pdb;
        if (!std.mem.eql(u8, &dump_pdb.guid, &own.guid) or dump_pdb.age != own.age) break :problem .pdb_mismatch;
        const got = session.loaded() orelse break :problem .pdb_not_loaded;
        if (!got.matches(dump_pdb)) break :problem .pdb_not_loaded;
        break :problem null;
    };
    try w.print("# kind={s} pid={d} start={d} format=" ++ format_name ++ " exe={s}", .{
        header.kind.text(), header.pid, header.start, header.exe,
    });
    if (header.pdb) |pdb| {
        try w.print(" pdb_guid={s} pdb_age={d}", .{ &dump.formatGuid(pdb.guid), pdb.age });
    } else {
        try w.writeAll(" pdb_guid=none pdb_age=0");
    }
    if (result.problem) |p| try w.print(" problem={s}", .{@tagName(p)});
    try w.writeByte('\n');
    if (read.failed) {
        result.unresolved += 1;
        try w.writeAll(lost_line);
    }

    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r").len == 0) continue;
        if (read.failed and dump.isFailedLine(line)) continue;
        result.pairs += 1;
        const pair = dump.parsePair(line) catch {
            result.unresolved += 1;
            try w.print("?unreadable-line-{d} none\n", .{result.pairs});
            continue;
        };
        if (result.problem) |p| {
            result.unresolved += 1;
            try w.print("?{s}:0x{x:0>16} {s}\n", .{ @tagName(p), pair.site, pair.role });
            continue;
        }
        // The call instruction, in the session's copy of the image: inside
        // both the dump's image and the one the session loaded, which can
        // differ in size (`openSelf` loads this process's own).
        if (pair.site <= header.base or pair.site - header.base > @min(header.size, session.size)) {
            result.unresolved += 1;
            try w.print("?outside-image:0x{x:0>16} {s}\n", .{ pair.site, pair.role });
            continue;
        }
        const address = session.base + (pair.site - header.base) - 1;
        const location = (try session.locate(a, address)) orelse {
            result.unresolved += 1;
            try w.print("?no-symbol:0x{x:0>16} {s}\n", .{ pair.site, pair.role });
            continue;
        };
        defer location.deinit(a);
        const file = try keyFile(a, location.file, root);
        defer a.free(file);
        try w.print("{s}:", .{file});
        try writeName(w, location.name);
        try w.print(" {s}\n", .{pair.role});
    }
}

/// The test exe's symbolise mode (§1 step 3 of the 1A.2(d) plan): reads
/// every `.pairs` dump in `raw_env`'s directory, symbolises each against
/// the image of its header's exe name in `images_env`'s directory, writes
/// it under its own name to `out_env`'s directory, prints a line per dump
/// and a summary to stderr (never a path), and exits 0 only when every pair
/// of every dump was named. `isolated.runChildIfRequested` calls it.
pub fn runFromEnvironment() noreturn {
    const code = runDirectories(std.heap.page_allocator) catch |err| code: {
        std.debug.print("symbolise: failed: {s}\n", .{@errorName(err)});
        break :code 2;
    };
    std.process.exit(code);
}

/// An environment variable's path, null when it is unset: a path from the
/// environment is drive-absolute or refused (error.NotDriveAbsolute), as
/// the dump directory is (`dump.isDriveAbsolute`).
pub fn envPath(a: Allocator, name: []const u8) !?[]u8 {
    const value = std.process.getEnvVarOwned(a, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    errdefer a.free(value);
    const wide = try std.unicode.wtf8ToWtf16LeAlloc(a, value);
    defer a.free(wide);
    if (!dump.isDriveAbsolute(wide)) return error.NotDriveAbsolute;
    return value;
}

/// A dump's exe name as an image file name: one plain name, no directory.
fn plainFileName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c < 0x20 or c == '\\' or c == '/' or c == ':') return false;
    }
    return true;
}

fn runDirectories(a: Allocator) !u8 {
    const raw_path = (try envPath(a, raw_env)) orelse return error.NoRawDirectory;
    const out_path = (try envPath(a, out_env)) orelse return error.NoOutputDirectory;
    const images_path = (try envPath(a, images_env)) orelse images: {
        const self_exe = try std.fs.selfExePathAlloc(a);
        break :images try a.dupe(u8, std.fs.path.dirname(self_exe) orelse return error.NoImagesDirectory);
    };
    const root = (try envPath(a, root_env)) orelse root: {
        var own = try Session.openSelf(a);
        defer own.close();
        break :root try own.sourceRoot(a);
    };

    var raw_dir = try std.fs.openDirAbsolute(raw_path, .{ .iterate = true });
    defer raw_dir.close();
    var out_dir = try std.fs.openDirAbsolute(out_path, .{});
    defer out_dir.close();

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    var it = raw_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, dump.extension)) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    var totals: struct { dumps: usize = 0, pairs: usize = 0, unresolved: usize = 0, problems: usize = 0 } = .{};
    for (names.items) |name| {
        const raw = try raw_dir.readFileAlloc(a, name, 16 << 20);
        defer a.free(raw);
        const result = try symboliseFile(a, raw, images_path, root);
        defer result.deinit(a);
        const file = try out_dir.createFile(name, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(result.text);
        totals.dumps += 1;
        totals.pairs += result.pairs;
        totals.unresolved += result.unresolved;
        totals.problems += @intFromBool(result.problem != null);
        std.debug.print("symbolise: {s} pairs={d} unresolved={d} problem={s}\n", .{
            name, result.pairs, result.unresolved, if (result.problem) |p| @tagName(p) else "none",
        });
    }
    std.debug.print("symbolise: {d} dumps, {d} pairs, {d} unresolved, {d} with a problem\n", .{
        totals.dumps, totals.pairs, totals.unresolved, totals.problems,
    });
    return if (totals.unresolved == 0 and totals.problems == 0) 0 else 1;
}

/// One raw dump, symbolised against its image in `images_path`.
fn symboliseFile(a: Allocator, raw: []const u8, images_path: []const u8, root: []const u8) !Result {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.first();
    const read = readHeader(raw) orelse return .{ .text = try a.dupe(u8, ""), .problem = .bad_header };
    // A failed dump is refused whatever its image, so none is looked for.
    if (read.failed) return problemOnly(a, raw, .append_failed);
    const header = read.header;
    var exe_buf: [512]u8 = undefined;
    const exe = dump.unescape(&exe_buf, header.exe) catch "";
    if (!plainFileName(exe)) return problemOnly(a, raw, .no_image);
    const image_path = try std.fs.path.join(a, &.{ images_path, exe });
    defer a.free(image_path);
    const image_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, image_path);
    defer a.free(image_w);
    const image_pdb = (imagePdb(image_w) catch return problemOnly(a, raw, .no_image)) orelse
        return problemOnly(a, raw, .no_pdb);
    var session = Session.open(a, image_w, header.base, header.size) catch return problemOnly(a, raw, .no_image);
    defer session.close();
    return symbolise(a, raw, &session, image_pdb, root);
}

/// The header kept and every pair unqualified, for a dump with no image.
fn problemOnly(a: Allocator, raw: []const u8, problem: Problem) Allocator.Error!Result {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var result: Result = .{ .text = undefined, .problem = problem };
    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.first();
    const read = readHeader(raw);
    const failed = if (read) |r| r.failed else false;
    const w = &out.writer;
    if (read) |r| {
        w.print("# kind={s} pid={d} start={d} format=" ++ format_name ++ " exe={s} problem={s}\n", .{
            r.header.kind.text(), r.header.pid, r.header.start, r.header.exe, @tagName(problem),
        }) catch return error.OutOfMemory;
    }
    if (problem == .append_failed) {
        result.unresolved += 1;
        w.writeAll(lost_line) catch return error.OutOfMemory;
    }
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r").len == 0) continue;
        if (failed and dump.isFailedLine(line)) continue;
        result.pairs += 1;
        result.unresolved += 1;
        const pair = dump.parsePair(line) catch {
            w.print("?unreadable-line-{d} none\n", .{result.pairs}) catch return error.OutOfMemory;
            continue;
        };
        w.print("?{s}:0x{x:0>16} {s}\n", .{ @tagName(problem), pair.site, pair.role }) catch return error.OutOfMemory;
    }
    result.text = try out.toOwnedSlice();
    return result;
}

/// An image file's own CodeView record, read from the file mapped as an
/// image (nothing of it runs): null for an image with none (a stripped
/// build), error.NoImage for a file that cannot be mapped or parsed.
fn imagePdb(path: [:0]const u16) error{NoImage}!?dump.Pdb {
    const handle = LoadLibraryExW(path.ptr, null, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE) orelse
        return error.NoImage;
    defer _ = FreeLibrary(handle);
    // A data-file mapping's handle carries flags in its low bits.
    const base = @intFromPtr(handle) & ~@as(usize, 3);
    const head: [*]const u8 = @ptrFromInt(base);
    const size = dump.sizeOfImage(head[0..0x1000]) catch return error.NoImage;
    const image = dump.parseImage(head[0..size]) catch return error.NoImage;
    const pdb = image.pdb orelse return null;
    // The name points into the mapping, which closes here.
    return .{ .guid = pdb.guid, .age = pdb.age, .name = "" };
}

const testing = std.testing;

test "DbgHelp's structs have the SDK's x64 sizes and offsets" {
    try testing.expectEqual(88, @sizeOf(SymbolInfoW));
    try testing.expectEqual(32, @offsetOf(SymbolInfoW, "ModBase"));
    try testing.expectEqual(48, @offsetOf(SymbolInfoW, "Value"));
    try testing.expectEqual(76, @offsetOf(SymbolInfoW, "NameLen"));
    try testing.expectEqual(80, @offsetOf(SymbolInfoW, "MaxNameLen"));
    try testing.expectEqual(84, @offsetOf(SymbolInfoW, "Name"));
    try testing.expectEqual(40, @sizeOf(ImagehlpLineW64));
    try testing.expectEqual(16, @offsetOf(ImagehlpLineW64, "LineNumber"));
    try testing.expectEqual(24, @offsetOf(ImagehlpLineW64, "FileName"));
    try testing.expectEqual(32, @offsetOf(ImagehlpLineW64, "Address"));
    try testing.expectEqual(3264, @sizeOf(ImagehlpModuleW64));
    try testing.expectEqual(8, @offsetOf(ImagehlpModuleW64, "BaseOfImage"));
    try testing.expectEqual(32, @offsetOf(ImagehlpModuleW64, "SymType"));
    try testing.expectEqual(1636, @offsetOf(ImagehlpModuleW64, "CVSig"));
    try testing.expectEqual(3204, @offsetOf(ImagehlpModuleW64, "PdbSig70"));
    try testing.expectEqual(3220, @offsetOf(ImagehlpModuleW64, "PdbAge"));
    try testing.expectEqual(3224, @offsetOf(ImagehlpModuleW64, "PdbUnmatched"));
    try testing.expectEqual(3232, @offsetOf(ImagehlpModuleW64, "LineNumbers"));
    try testing.expectEqual(3256, @offsetOf(ImagehlpModuleW64, "Reserved"));
}

test "a key's file is relative to the source root with /, and a name's control bytes are escaped" {
    const a = testing.allocator;
    const inside = try keyFile(a, "C:\\Work\\Noctty\\src\\termio\\mailbox.zig", "c:/work/noctty\\");
    defer a.free(inside);
    try testing.expectEqualStrings("src/termio/mailbox.zig", inside);
    const outside = try keyFile(a, "D:\\other\\x.zig", "C:\\Work\\Noctty\\");
    defer a.free(outside);
    try testing.expectEqualStrings("D:/other/x.zig", outside);

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeName(&out.writer, "test.a\tb\nc d\x7f");
    try testing.expectEqualStrings("test.a\\x09b\\x0ac d\\x7f", out.written());

    try testing.expect(plainFileName("ghostty-test.exe"));
    try testing.expect(!plainFileName("..\\noctty.exe"));
    try testing.expect(!plainFileName("C:noctty.exe"));
    try testing.expect(!plainFileName(".."));
    try testing.expect(!plainFileName(""));
    try testing.expectEqual(@as(?usize, 6), dirLength(std.unicode.utf8ToUtf16LeStringLiteral("C:\\bin\\a.exe")));
}

/// Sites of the shapes §2.7 RQ10 names, each recording the address its
/// call resumes at, as `StateMutex`'s acquire does.
const Shapes = struct {
    var sites: [8]usize = @splat(0);

    inline fn record(slot: usize) void {
        @call(.never_tail, recordImpl, .{slot});
    }

    noinline fn recordImpl(slot: usize) void {
        sites[slot] = @returnAddress();
    }

    noinline fn symbolisePlainSite() void {
        record(0);
    }

    const Holder = struct {
        noinline fn symboliseMethodSite() void {
            record(1);
        }

        const Inner = struct {
            noinline fn symboliseNestedSite() void {
                record(2);
            }
        };
    };

    noinline fn symboliseComptimeSite(comptime first: bool) void {
        record(if (first) 3 else 4);
    }

    inline fn inlineSite() void {
        record(5);
    }

    noinline fn symboliseInlineCaller() void {
        inlineSite();
    }
};

test "symbolise names each site shape's acquiring function in this file" {
    const a = testing.allocator;
    Shapes.symbolisePlainSite();
    Shapes.Holder.symboliseMethodSite();
    Shapes.Holder.Inner.symboliseNestedSite();
    Shapes.symboliseComptimeSite(true);
    Shapes.symboliseComptimeSite(false);
    Shapes.symboliseInlineCaller();
    record_test_site();

    var session = try Session.openSelf(a);
    defer session.close();
    const own = dump.selfModule().?;
    const pdb = own.pdb orelse return error.SkipZigTest; // a stripped build has no PDB
    try testing.expect(session.loaded().?.matches(pdb));
    const root = try session.sourceRoot(a);
    defer a.free(root);

    // A raw dump of the sites, as this process's recorder would write it.
    var raw: std.Io.Writer.Allocating = .init(a);
    defer raw.deinit();
    try raw.writer.print("# kind=child pid=1 start=2 format=raw-1 exe=ghostty-test.exe base=0x{x:0>16} " ++
        "size=0x{x:0>8} pdb_guid={s} pdb_age={d} pdb=ghostty-test.pdb\n", .{ own.base, own.size, &dump.formatGuid(pdb.guid), pdb.age });
    for (Shapes.sites[0..7]) |site| {
        var pair_line: [dump.pair_line_max]u8 = undefined;
        try raw.writer.writeAll(dump.formatPair(&pair_line, site, .ui, .lock));
    }
    var line: [dump.pair_line_max]u8 = undefined;
    try raw.writer.writeAll(dump.formatPair(&line, own.base + own.size + 16, .termio, .lock));

    const result = try symbolise(a, raw.written(), &session, pdb, root);
    defer result.deinit(a);
    try testing.expectEqual(@as(?Problem, null), result.problem);
    try testing.expectEqual(@as(usize, 8), result.pairs);
    try testing.expectEqual(@as(usize, 1), result.unresolved);
    var lines = std.mem.splitScalar(u8, result.text, '\n');
    const header = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, header, "# kind=child pid=1 start=2 format=sym-1 exe=ghostty-test.exe pdb_guid="));
    try expectShapeLine(lines.next().?, "symbolisePlainSite");
    try expectShapeLine(lines.next().?, "symboliseMethodSite");
    try expectShapeLine(lines.next().?, "symboliseNestedSite");
    // Each instantiation is its own symbol, its suffix the compare's to strip.
    const first = lines.next().?;
    const second = lines.next().?;
    if (names_attributed) {
        try testing.expect(std.mem.startsWith(u8, first, "src/sync/symbolise.zig:symboliseComptimeSite__anon_"));
        try testing.expect(std.mem.startsWith(u8, second, "src/sync/symbolise.zig:symboliseComptimeSite__anon_"));
        try testing.expect(!std.mem.eql(u8, first, second));
    } else {
        try expectShapeLine(first, null);
        try expectShapeLine(second, null);
    }
    // 0.15.2 attributes a site in an inline fn to its caller (§19.1).
    try expectShapeLine(lines.next().?, if (builtin.mode == .Debug) "symboliseInlineCaller" else null);
    try expectShapeLine(lines.next().?, "test.symbolise names each site shape's acquiring function in this file");
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&line, "?outside-image:0x{x:0>16} termio", .{own.base + own.size + 16}),
        lines.next().?,
    );
    try testing.expectEqualStrings("", lines.next().?);

    // A dump that says its image is bigger than the one the session loaded:
    // an address past the session's image is refused before DbgHelp sees it.
    var bigger: std.Io.Writer.Allocating = .init(a);
    defer bigger.deinit();
    try bigger.writer.print("# kind=child pid=1 start=2 format=raw-1 exe=ghostty-test.exe base=0x{x:0>16} " ++
        "size=0x{x:0>8} pdb_guid={s} pdb_age={d} pdb=ghostty-test.pdb\n", .{ own.base, own.size + 0x10000, &dump.formatGuid(pdb.guid), pdb.age });
    try bigger.writer.writeAll(dump.formatPair(&line, own.base + own.size + 16, .ui, .lock));
    const past = try symbolise(a, bigger.written(), &session, pdb, root);
    defer past.deinit(a);
    try testing.expectEqual(@as(usize, 1), past.unresolved);
    try testing.expect(std.mem.endsWith(u8, past.text, try std.fmt.bufPrint(&line, "\n?outside-image:0x{x:0>16} ui\n", .{own.base + own.size + 16})));

    // Another build's dump: its pairs are refused, not named.
    var other = pdb;
    other.age +%= 1;
    const refused = try symbolise(a, raw.written(), &session, other, root);
    defer refused.deinit(a);
    try testing.expectEqual(@as(?Problem, .pdb_mismatch), refused.problem);
    try testing.expectEqual(@as(usize, 8), refused.unresolved);
    try testing.expect(std.mem.indexOf(u8, refused.text, " problem=pdb_mismatch\n") != null);
    try testing.expect(std.mem.indexOf(u8, refused.text, "symbolise.zig") == null);
    // No header.
    const headless = try symbolise(a, "0x0000000000000010 lock ui\n", &session, pdb, root);
    defer headless.deinit(a);
    try testing.expectEqual(@as(?Problem, .bad_header), headless.problem);
    try testing.expectEqualStrings("", headless.text);
    // A header line its writer did not finish (no LF) is no header either.
    const unterminated = try symbolise(a, std.mem.sliceTo(raw.written(), '\n'), &session, pdb, root);
    defer unterminated.deinit(a);
    try testing.expectEqual(@as(?Problem, .bad_header), unterminated.problem);
}

/// One symbolised line of the site-shape test: `name`'s key with role `ui`
/// where this build checks names (RQ16), else, or for a null `name`, the
/// role and a key that names a file.
fn expectShapeLine(line: []const u8, comptime name: ?[]const u8) !void {
    if (names_attributed) {
        if (name) |n| return testing.expectEqualStrings("src/sync/symbolise.zig:" ++ n ++ " ui", line);
    }
    try testing.expect(std.mem.endsWith(u8, line, " ui"));
    try testing.expect(line[0] != '?' and std.mem.indexOf(u8, line, ".zig:") != null);
}

/// The test block's own site (a test body is `test.<name>`).
inline fn record_test_site() void {
    Shapes.record(6);
}

test "the image file's own CodeView record is this process's" {
    const own = dump.selfModule().?;
    const pdb = own.pdb orelse return error.SkipZigTest;
    var buf: [32768]u16 = undefined;
    const n = win32_sys.GetModuleFileNameW(null, &buf, buf.len - 1);
    buf[n] = 0;
    const file_pdb = (try imagePdb(buf[0..n :0])) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(pdb.guid, file_pdb.guid);
    try testing.expectEqual(pdb.age, file_pdb.age);
    try testing.expectError(error.NoImage, imagePdb(std.unicode.utf8ToUtf16LeStringLiteral("C:\\no\\such\\image.exe")));
}

/// The writer-failure control's one site (stone round 3's Sol M2): it
/// records the address its call resumes at, as `StateMutex`'s acquire does.
const LostPairSite = struct {
    var site: usize = 0;

    inline fn record() void {
        @call(.never_tail, recordImpl, .{});
    }

    noinline fn recordImpl() void {
        site = @returnAddress();
    }

    noinline fn symboliseLostPairSite() void {
        record();
    }
};

const recorder = @import("recorder.zig");
const compare = @import("compare.zig");

/// The control's recorders, each with a test's directory as its dump.
const ControlRecorder = recorder.Recorder(8);

test "a dump whose writer failed after one pair fails the compare, though that pair is in the table" {
    const a = testing.allocator;
    LostPairSite.symboliseLostPairSite();
    const site = LostPairSite.site;
    var session = try Session.openSelf(a);
    defer session.close();
    const pdb = (dump.selfModule().?).pdb orelse return error.SkipZigTest; // a stripped build has no PDB
    const root = try session.sourceRoot(a);
    defer a.free(root);

    // The writer writes the child's first pair, an allowed one, and loses
    // its second, the off-table one, as a full disk loses it.
    var dir = try dump.TestDir.init();
    defer dir.deinit();
    var fault: dump.Fault = .{ .pairs_before = 1 };
    var slots = ControlRecorder.empty;
    var rec: ControlRecorder = .{ .slots = &slots, .sink = .{
        .target = .{ .directory = dir.path },
        .kind = .child,
        .fault = &fault,
    } };
    defer rec.sink.close();
    rec.record(site, .ui, .lock);
    rec.record(site, .termio, .lock);
    try testing.expectEqual(@as(u32, 1), rec.sink.failedAppends());
    const raw = try dir.read();
    defer a.free(raw);

    // What the writer left before the fix: the same header, unmarked, and
    // the kept pair. It names the table's one row and passes, as Sol
    // measured with role_compare3.py on test 13's dump.
    var raw_lines = std.mem.splitScalar(u8, raw, '\n');
    const marked_header = raw_lines.next().?;
    try testing.expectEqual(@as(u8, dump.failed_mark), marked_header[0]);
    const kept_line = raw_lines.next().?;
    const prefix = try std.fmt.allocPrint(a, "#{s}\n{s}\n", .{ marked_header[1..], kept_line });
    defer a.free(prefix);
    const named = try symbolise(a, prefix, &session, pdb, root);
    defer named.deinit(a);
    try testing.expectEqual(@as(?Problem, null), named.problem);
    var named_lines = std.mem.splitScalar(u8, named.text, '\n');
    _ = named_lines.next();
    const kept = named_lines.next().?;
    const space = std.mem.lastIndexOfScalar(u8, kept, ' ').?;
    try testing.expectEqualStrings("ui", kept[space + 1 ..]);
    if (!compare.qualified(kept[0..space])) {
        // This build names no site (RQ16); the compare has nothing to key.
        if (!names_checked) return error.SkipZigTest;
        return error.TestUnexpectedResult;
    }
    const table = try std.fmt.allocPrint(a, "{s}\tui\n", .{kept[0..space]});
    defer a.free(table);
    var hazard = try compare.isolated(a, table, null, &.{.{ .name = "c.pairs", .text = named.text }}, .{});
    defer hazard.deinit();
    try testing.expect(hazard.passed());

    // The lost pair is the off-table one: a dump that kept both fails one
    // PAIR-OUTSIDE-TABLE naming it.
    var whole_dir = try dump.TestDir.init();
    defer whole_dir.deinit();
    var whole_slots = ControlRecorder.empty;
    var whole: ControlRecorder = .{ .slots = &whole_slots, .sink = .{ .target = .{ .directory = whole_dir.path }, .kind = .child } };
    defer whole.sink.close();
    whole.record(site, .ui, .lock);
    whole.record(site, .termio, .lock);
    const whole_raw = try whole_dir.read();
    defer a.free(whole_raw);
    const whole_named = try symbolise(a, whole_raw, &session, pdb, root);
    defer whole_named.deinit(a);
    var off = try compare.isolated(a, table, null, &.{.{ .name = "c.pairs", .text = whole_named.text }}, .{});
    defer off.deinit();
    try testing.expectEqual(@as(usize, 1), off.failures.items.len);
    try testing.expectEqual(@as(usize, 1), off.count(.pair_outside_table));
    var line_buf: [512]u8 = undefined;
    try testing.expect(off.hasLine(try std.fmt.bufPrint(&line_buf, "FAIL PAIR-OUTSIDE-TABLE c.pairs: ({s}, termio)", .{kept[0..space]})));

    // The marked dump: the symboliser refuses it, and the compare fails it.
    const refused = try symbolise(a, raw, &session, pdb, root);
    defer refused.deinit(a);
    try testing.expectEqual(@as(?Problem, .append_failed), refused.problem);
    try testing.expectEqual(@as(usize, 1), refused.pairs);
    try testing.expectEqual(@as(usize, 2), refused.unresolved);
    var refused_lines = std.mem.splitScalar(u8, refused.text, '\n');
    const refused_header = refused_lines.next().?;
    try testing.expect(std.mem.startsWith(u8, refused_header, "# kind=child pid="));
    try testing.expect(std.mem.endsWith(u8, refused_header, " problem=append_failed"));
    try testing.expectEqualStrings(lost_line, try std.fmt.bufPrint(&line_buf, "{s}\n", .{refused_lines.next().?}));
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&line_buf, "?append_failed:0x{x:0>16} ui", .{site}),
        refused_lines.next().?,
    );
    try testing.expectEqualStrings("", refused_lines.next().?);
    var failed = try compare.isolated(a, table, null, &.{.{ .name = "c.pairs", .text = refused.text }}, .{});
    defer failed.deinit();
    try testing.expect(!failed.passed());
    try testing.expectEqual(@as(usize, 1), failed.count(.bad_dump));
    // The prototype reads only a header's first three fields: without the
    // problem field the same dump still fails, on the lost line's key.
    const unflagged = try std.mem.replaceOwned(u8, a, refused.text, " problem=append_failed", "");
    defer a.free(unflagged);
    var prototype = try compare.isolated(a, table, null, &.{.{ .name = "c.pairs", .text = unflagged }}, .{});
    defer prototype.deinit();
    try testing.expectEqual(@as(usize, 2), prototype.count(.unqualified_key));
    try testing.expect(prototype.hasLine("FAIL UNQUALIFIED-KEY c.pairs: (?append_failed:pairs-lost, none) names no .zig file"));

    // Once writes work again the lost pair is written on its next record;
    // the dump stays failed, and is still refused.
    fault.pairs_before = std.math.maxInt(u32);
    rec.record(site, .termio, .lock);
    const later = try dir.read();
    defer a.free(later);
    const still = try symbolise(a, later, &session, pdb, root);
    defer still.deinit(a);
    try testing.expectEqual(@as(?Problem, .append_failed), still.problem);
    try testing.expectEqual(@as(usize, 2), still.pairs);
}

test "a failed dump is refused without its image, and with no pair still fails" {
    const a = testing.allocator;
    // The writer lost the process's first pair: the header alone, marked.
    const raw = "! kind=test-exe pid=7 start=8 format=raw-1 exe=ghostty-test.exe base=0x0000000000010000 " ++
        "size=0x00001000 pdb_guid=none pdb_age=0 pdb=none\n! append-failed win32=112\n";
    const result = try symboliseFile(a, raw, "C:\\no\\such\\images", "C:\\src\\");
    defer result.deinit(a);
    try testing.expectEqual(@as(?Problem, .append_failed), result.problem);
    try testing.expectEqual(@as(usize, 0), result.pairs);
    try testing.expectEqual(@as(usize, 1), result.unresolved);
    try testing.expectEqualStrings("# kind=test-exe pid=7 start=8 format=sym-1 exe=ghostty-test.exe problem=append_failed\n" ++
        lost_line, result.text);
}
