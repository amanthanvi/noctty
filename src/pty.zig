const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("os/main.zig");
const windows = internal_os.windows;
const posix = std.posix;
const assert = @import("quirks.zig").inlineAssert;

const log = std.log.scoped(.pty);

pub const ConPtySource = enum {
    bundled,
    inbox,
};

pub const ConPtyInfo = struct {
    source: ConPtySource,
    dll_path: ?[]const u8,

    pub fn jsonStringify(
        self: *const ConPtyInfo,
        jws: anytype,
    ) std.Io.Writer.Error!void {
        try jws.beginObject();
        try jws.objectField("source");
        try jws.write(self.source);
        try jws.endObject();
    }
};

/// Returns the process-wide ConPTY selection. On Windows this initializes the
/// same resolver used by Pty.open; other platforms do not have ConPTY.
pub fn conPtyInfo() ?ConPtyInfo {
    if (comptime builtin.os.tag != .windows) return null;
    return WindowsConPty.functions().info();
}

pub const conpty_fallback_banner =
    "Bundled ConPTY is unavailable; using the in-box conhost. Kitty graphics and Sixel passthrough may be stripped on this Windows build.";

pub fn hasPendingConPtyFallbackBanner() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return WindowsConPty.fallback_banner_pending.load(.acquire);
}

pub fn takeConPtyFallbackBanner() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return WindowsConPty.fallback_banner_pending.swap(false, .acq_rel);
}

/// Redeclare this winsize struct so we can just use a Zig struct. This
/// layout should be correct on all tested platforms. The defaults on this
/// are some reasonable screen size but you should probably not use them.
pub const winsize = extern struct {
    ws_row: u16 = 100,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

pub const Pty = switch (builtin.os.tag) {
    .windows => WindowsPty,
    .ios => NullPty,
    else => PosixPty,
};

/// A Windows pseudo-terminal session whose console process already exists.
/// The client handle is retained only for its eventual exit code; output-pipe
/// EOF remains authoritative because descendants can outlive the root client.
pub const AdoptedSession = if (builtin.os.tag == .windows) struct {
    pty: Pty,
    client_process: windows.HANDLE,
} else void;

/// The modes of a pty. Not all of these modes are supported on
/// all platforms but all platforms share the same mode struct.
///
/// The default values of fields in this struct are set to the
/// most typical values for a pty. This makes it easier for cross-platform
/// code which doesn't support all of the modes to work correctly.
pub const Mode = packed struct {
    /// ICANON on POSIX
    canonical: bool = true,

    /// ECHO on POSIX
    echo: bool = true,
};

pub const ProcessInfo = enum {
    /// The PID of the process that controls the PTY.
    foreground_pid,
    /// Gets the name of the slave PTY. Returned name points to an internal buffer
    /// so it should not be modified or freed.
    tty_name,

    pub fn Type(comptime info: ProcessInfo) type {
        return switch (info) {
            .foreground_pid => u64,
            .tty_name => [:0]const u8,
        };
    }
};

// A pty implementation that does nothing.
//
// TODO: This should be removed. This is only temporary until we have
// a termio that doesn't use a pty. This isn't used in any user-facing
// artifacts, this is just a stopgap to get compilation to work on iOS.
const NullPty = struct {
    pub const Error = OpenError || GetModeError || SetSizeError || ChildPreExecError;

    pub const Fd = posix.fd_t;

    master: Fd,
    slave: Fd,

    pub const OpenError = error{};

    pub fn open(size: winsize) OpenError!Pty {
        _ = size;
        return .{ .master = 0, .slave = 0 };
    }

    pub fn deinit(self: *Pty) void {
        _ = self;
    }

    pub const GetModeError = error{GetModeFailed};

    pub fn getMode(self: Pty) GetModeError!Mode {
        _ = self;
        return .{};
    }

    pub const SetSizeError = error{};

    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        _ = self;
        _ = size;
    }

    pub const ChildPreExecError = error{};

    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        _ = self;
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(_: *Pty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};

/// Posix PTY creation and management. This is just a thin layer on top
/// of Posix syscalls. The caller is responsible for detail-oriented handling
/// of the returned file handles.
const PosixPty = struct {
    pub const Error = OpenError || GetModeError || GetSizeError || SetSizeError || ChildPreExecError;

    pub const Fd = posix.fd_t;

    const c = @import("pty-c");

    /// The file descriptors for the master and slave side of the pty.
    /// The slave side is never closed automatically by this struct
    /// so the caller is responsible for closing it if things
    /// go wrong.
    master: Fd,
    slave: Fd,

    /// Buffer for storage of slave tty name so that we don't have to recompute
    /// it every time we need it.
    tty_name_buf: [std.fs.max_path_bytes:0]u8 = undefined,
    /// The name of slave tty. If `null` it has not yet been computed or
    /// may not be available. Should not be accessed directly, but through
    /// `self.getProcessInfo(.tty_name)`
    tty_name: ?[:0]const u8 = null,

    pub const OpenError = error{OpenptyFailed};

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize) OpenError!Pty {
        // Need to copy so that it becomes non-const.
        var sizeCopy = size;

        var master_fd: Fd = undefined;
        var slave_fd: Fd = undefined;
        if (c.openpty(
            &master_fd,
            &slave_fd,
            null,
            null,
            @ptrCast(&sizeCopy),
        ) < 0)
            return error.OpenptyFailed;
        errdefer {
            _ = posix.system.close(master_fd);
            _ = posix.system.close(slave_fd);
        }

        // Set CLOEXEC on the master fd, only the slave fd should be inherited
        // by the child process (shell/command).
        cloexec: {
            const flags = posix.fcntl(master_fd, posix.F.GETFD, 0) catch |err| {
                log.warn("error getting flags for master fd err={}", .{err});
                break :cloexec;
            };

            _ = posix.fcntl(
                master_fd,
                posix.F.SETFD,
                flags | posix.FD_CLOEXEC,
            ) catch |err| {
                log.warn("error setting CLOEXEC on master fd err={}", .{err});
                break :cloexec;
            };
        }

        // Enable UTF-8 mode. I think this is on by default on Linux but it
        // is NOT on by default on macOS so we ensure that it is always set.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master_fd, &attrs) != 0)
            return error.OpenptyFailed;
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0)
            return error.OpenptyFailed;

        return .{
            .master = master_fd,
            .slave = slave_fd,
            .tty_name_buf = undefined,
            .tty_name = null,
        };
    }

    pub fn deinit(self: *Pty) void {
        _ = posix.system.close(self.master);
        self.* = undefined;
    }

    pub const GetModeError = error{GetModeFailed};

    pub fn getMode(self: Pty) GetModeError!Mode {
        var attrs: c.termios = undefined;
        if (c.tcgetattr(self.master, &attrs) != 0)
            return error.GetModeFailed;

        return .{
            .canonical = (attrs.c_lflag & c.ICANON) != 0,
            .echo = (attrs.c_lflag & c.ECHO) != 0,
        };
    }

    pub const GetSizeError = error{IoctlFailed};

    /// Return the size of the pty.
    pub fn getSize(self: Pty) GetSizeError!winsize {
        var ws: winsize = undefined;
        if (c.ioctl(self.master, c.TIOCGWINSZ, @intFromPtr(&ws)) < 0)
            return error.IoctlFailed;

        return ws;
    }

    pub const SetSizeError = error{IoctlFailed};

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        if (c.ioctl(self.master, c.TIOCSWINSZ, @intFromPtr(&size)) < 0)
            return error.IoctlFailed;
    }

    pub const ChildPreExecError = error{ OperationNotSupported, ProcessGroupFailed, SetControllingTerminalFailed };

    /// This should be called prior to exec in the forked child process
    /// in order to setup the tty properly.
    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        // Reset our signals
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.ABRT, &sa, null);
        posix.sigaction(posix.SIG.ALRM, &sa, null);
        posix.sigaction(posix.SIG.BUS, &sa, null);
        posix.sigaction(posix.SIG.CHLD, &sa, null);
        posix.sigaction(posix.SIG.FPE, &sa, null);
        posix.sigaction(posix.SIG.HUP, &sa, null);
        posix.sigaction(posix.SIG.ILL, &sa, null);
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.PIPE, &sa, null);
        posix.sigaction(posix.SIG.SEGV, &sa, null);
        posix.sigaction(posix.SIG.TRAP, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
        posix.sigaction(posix.SIG.QUIT, &sa, null);

        // Create a new process group
        if (c.setsid() < 0) return error.ProcessGroupFailed;

        // Set controlling terminal
        switch (posix.errno(c.ioctl(self.slave, c.TIOCSCTTY, @as(c_ulong, 0)))) {
            .SUCCESS => {},
            else => |err| {
                log.err("error setting controlling terminal errno={}", .{err});
                return error.SetControllingTerminalFailed;
            },
        }

        // Can close master/slave pair now
        posix.close(self.slave);
        posix.close(self.master);
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *PosixPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (info) {
            .foreground_pid => {
                switch (builtin.os.tag) {
                    .linux => {
                        const linux = std.os.linux;
                        var pgrp: i32 = undefined;
                        const rc = linux.tcgetpgrp(self.master, &pgrp);
                        switch (linux.E.init(rc)) {
                            .SUCCESS => return @intCast(pgrp),
                            else => return null,
                        }
                    },
                    else => {
                        const rc = c.tcgetpgrp(self.master);
                        if (rc < 0) return null;
                        return @intCast(rc);
                    },
                }
            },
            .tty_name => {
                if (self.tty_name) |tty_name| return tty_name;

                switch (builtin.os.tag) {
                    .macos => {
                        // The macOS TIOCPTYGNAME ioctl does not allow us to
                        // specify the length of the buffer passed to it, but
                        // expects it to be at least 128 bytes long.
                        assert(self.tty_name_buf.len >= 128);
                        switch (posix.errno(c.ioctl(self.master, c.TIOCPTYGNAME, @intFromPtr(&self.tty_name_buf)))) {
                            .SUCCESS => {
                                const tty_name: [:0]const u8 = std.mem.sliceTo(&self.tty_name_buf, 0);
                                self.tty_name = tty_name;
                                return tty_name;
                            },
                            else => |err| {
                                log.err("error getting name of slave PTY errno={t}", .{err});
                                return null;
                            },
                        }
                    },
                    .linux => {
                        if (c.ptsname_r(self.master, &self.tty_name_buf, self.tty_name_buf.len) != 0) return null;
                        const tty_name: [:0]const u8 = std.mem.sliceTo(&self.tty_name_buf, 0);
                        self.tty_name = tty_name;
                        return tty_name;
                    },
                    else => return null,
                }
            },
        };
    }
};

const WindowsConPty = struct {
    const BundledLoadError = error{
        PathUnavailable,
        NotFound,
        LoadFailed,
        OpenConsoleMissing,
        OpenConsoleWrongArch,
        CreateSymbolMissing,
        ResizeSymbolMissing,
        CloseSymbolMissing,
    };

    const Functions = struct {
        source: ConPtySource,
        module: ?windows.HMODULE = null,
        bundled_path: ?[]const u8 = null,
        create: windows.exp.CreatePseudoConsoleFn,
        resize: windows.exp.ResizePseudoConsoleFn,
        close: windows.exp.ClosePseudoConsoleFn,

        fn info(self: *const Functions) ConPtyInfo {
            return .{
                .source = self.source,
                .dll_path = if (self.source == .bundled) self.bundled_path else null,
            };
        }
    };

    const inbox_functions: Functions = .{
        .source = .inbox,
        .create = &windows.exp.kernel32.CreatePseudoConsole,
        .resize = &windows.exp.kernel32.ResizePseudoConsole,
        .close = &windows.exp.kernel32.ClosePseudoConsole,
    };
    var bundled_functions: Functions = inbox_functions;
    var selected = std.atomic.Value(*const Functions).init(&inbox_functions);
    var resolver_once = std.once(initialize);
    /// Number of bundled pseudo consoles currently open in this process.
    /// Incremented under `backend_lock` when a bundled creation succeeds and
    /// decremented by `WindowsPty.deinit` after the handle is closed, so a
    /// zero here means no live handle would be split from the selection.
    var live_bundled_hpcons = std.atomic.Value(u32).init(0);
    var fallback_banner_pending = std.atomic.Value(bool).init(false);

    fn functions() *const Functions {
        resolver_once.call();
        return selected.load(.acquire);
    }

    /// Serializes backend selection, pseudo console creation, and the
    /// demotion decision into one critical section. Without it a bundled
    /// creation that already succeeded can be preempted before it records
    /// itself in `live_bundled_hpcons`; a concurrent open whose bundled
    /// creation failed then reads a stale zero, demotes the selection, and
    /// leaves a live bundled HPCON behind an in-box selection that
    /// `conPtyInfo` and the fallback banner both misreport. Opens happen once
    /// per surface and already spawn OpenConsole.exe, so the contention cost
    /// is irrelevant.
    var backend_lock: std.Thread.Mutex = .{};

    /// Pick the backend that will own a new pseudo console.
    ///
    /// `context` performs the creation attempt via `context.attempt(functions)`
    /// returning whether it succeeded; `WindowsPty.open` calls
    /// `CreatePseudoConsole` there and the concurrency test injects a
    /// deterministic outcome. Returns the backend that owns the pseudo
    /// console.
    ///
    /// A failed bundled creation demotes the whole process to the in-box
    /// conhost and retries there, but only while no bundled HPCON is live:
    /// demoting past a live one would split the process across two ConPTY
    /// implementations, so such an open fails with
    /// `error.BundledConptyInconsistent` instead. Once the last bundled
    /// handle closes the count returns to zero and demotion is allowed again.
    fn selectBackend(context: anytype) SelectError!*const Functions {
        backend_lock.lock();
        defer backend_lock.unlock();

        const initial = functions();
        if (context.attempt(initial)) {
            if (initial.source == .bundled) _ = live_bundled_hpcons.fetchAdd(1, .acq_rel);
            return initial;
        }
        if (initial.source != .bundled) return error.CreatePseudoConsoleFailed;
        const live = live_bundled_hpcons.load(.acquire);
        if (live != 0) {
            log.warn(
                "bundled ConPTY failed to create a pseudo console while {d} bundled pseudo console(s) are still open; refusing to mix ConPTY implementations in one process",
                .{live},
            );
            return error.BundledConptyInconsistent;
        }

        if (selected.cmpxchgStrong(
            initial,
            &inbox_functions,
            .acq_rel,
            .acquire,
        ) == null) {
            log.warn(
                "bundled ConPTY failed to create a pseudo console; using the in-box conhost — Kitty graphics (APC) and Sixel (DCS) passthrough may be silently stripped on this Windows build",
                .{},
            );
            signalFallbackBanner();
        }
        if (!context.attempt(&inbox_functions)) return error.CreatePseudoConsoleFailed;
        return &inbox_functions;
    }

    const SelectError = error{
        CreatePseudoConsoleFailed,
        BundledConptyInconsistent,
    };

    /// Called by `WindowsPty.deinit` after a bundled pseudo console has been
    /// closed through the implementation that created it.
    fn releaseBundledHpcon() void {
        const previous = live_bundled_hpcons.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
    }

    fn initialize() void {
        selected.store(resolve(), .release);
    }

    fn resolve() *const Functions {
        if (forceInbox()) {
            log.warn(
                "bundled ConPTY disabled by NOCTTY_CONPTY=inbox; using the in-box conhost — Kitty graphics (APC) and Sixel (DCS) passthrough may be silently stripped on this Windows build",
                .{},
            );
        } else {
            if (loadBundled()) |bundled| {
                log.info("using bundled ConPTY: {s}", .{bundled.bundled_path.?});
                bundled_functions = bundled;
                return &bundled_functions;
            } else |err| {
                const reason = switch (err) {
                    error.PathUnavailable => "bundled ConPTY path could not be resolved",
                    error.NotFound => "bundled ConPTY not found",
                    error.LoadFailed => "bundled ConPTY failed to load",
                    error.OpenConsoleMissing => "bundled ConPTY is missing OpenConsole.exe",
                    error.OpenConsoleWrongArch => "bundled OpenConsole.exe has the wrong architecture",
                    error.CreateSymbolMissing => "bundled ConPTY is missing CreatePseudoConsole",
                    error.ResizeSymbolMissing => "bundled ConPTY is missing ResizePseudoConsole",
                    error.CloseSymbolMissing => "bundled ConPTY is missing ClosePseudoConsole",
                };
                log.warn(
                    "{s}; using the in-box conhost — Kitty graphics (APC) and Sixel (DCS) passthrough may be silently stripped on this Windows build",
                    .{reason},
                );
                signalFallbackBanner();
            }
        }

        return &inbox_functions;
    }

    fn forceInbox() bool {
        const value = std.process.getEnvVarOwned(
            std.heap.page_allocator,
            "NOCTTY_CONPTY",
        ) catch return false;
        defer std.heap.page_allocator.free(value);

        return std.ascii.eqlIgnoreCase(value, "inbox");
    }

    fn loadBundled() BundledLoadError!Functions {
        var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_dir = std.fs.selfExeDirPath(&exe_dir_buf) catch
            return error.PathUnavailable;
        const path = std.fs.path.join(
            std.heap.page_allocator,
            &.{ exe_dir, "conpty.dll" },
        ) catch return error.PathUnavailable;
        errdefer std.heap.page_allocator.free(path);

        const path_w = std.unicode.wtf8ToWtf16LeAllocZ(
            std.heap.page_allocator,
            path,
        ) catch return error.PathUnavailable;
        defer std.heap.page_allocator.free(path_w);

        const flags = windows.exp.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
            windows.exp.LOAD_LIBRARY_SEARCH_SYSTEM32;
        const module = windows.kernel32.LoadLibraryExW(
            path_w.ptr,
            null,
            flags,
        ) orelse return switch (windows.kernel32.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND, .MOD_NOT_FOUND => error.NotFound,
            else => error.LoadFailed,
        };
        errdefer _ = windows.kernel32.FreeLibrary(module);

        const open_console_path = std.fs.path.join(
            std.heap.page_allocator,
            &.{ exe_dir, "OpenConsole.exe" },
        ) catch return error.PathUnavailable;
        defer std.heap.page_allocator.free(open_console_path);
        if (openConsoleMatchesArchitecture(open_console_path)) |matches| {
            if (!matches) return error.OpenConsoleWrongArch;
        } else |err| switch (err) {
            error.FileNotFound => return error.OpenConsoleMissing,
            else => return error.OpenConsoleMissing,
        }

        const create: windows.exp.CreatePseudoConsoleFn = @ptrCast(@alignCast(
            windows.kernel32.GetProcAddress(module, "CreatePseudoConsole") orelse
                return error.CreateSymbolMissing,
        ));
        const resize: windows.exp.ResizePseudoConsoleFn = @ptrCast(@alignCast(
            windows.kernel32.GetProcAddress(module, "ResizePseudoConsole") orelse
                return error.ResizeSymbolMissing,
        ));
        const close: windows.exp.ClosePseudoConsoleFn = @ptrCast(@alignCast(
            windows.kernel32.GetProcAddress(module, "ClosePseudoConsole") orelse
                return error.CloseSymbolMissing,
        ));

        return .{
            .source = .bundled,
            .module = module,
            .bundled_path = path,
            .create = create,
            .resize = resize,
            .close = close,
        };
    }

    fn openConsoleMatchesArchitecture(path: []const u8) !bool {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        var dos_header: [64]u8 = undefined;
        if (try file.readAll(&dos_header) != dos_header.len) return false;
        if (!std.mem.eql(u8, dos_header[0..2], "MZ")) return false;

        const pe_offset = std.mem.readInt(u32, dos_header[0x3c..0x40], .little);
        try file.seekTo(@as(u64, pe_offset));
        var pe_header: [6]u8 = undefined;
        if (try file.readAll(&pe_header) != pe_header.len) return false;
        if (!std.mem.eql(u8, pe_header[0..4], "PE\x00\x00")) return false;

        const expected: u16 = switch (builtin.cpu.arch) {
            .x86 => 0x014c,
            .x86_64 => 0x8664,
            .arm, .thumb => 0x01c4,
            .aarch64 => 0xaa64,
            else => return false,
        };
        return std.mem.readInt(u16, pe_header[4..6], .little) == expected;
    }

    fn signalFallbackBanner() void {
        if (comptime builtin.mode != .ReleaseFast) return;
        fallback_banner_pending.store(true, .release);
    }

    fn resetForTest() void {
        std.debug.assert(builtin.is_test);
        // No live HPCON may cross this reset or its module provenance would change.

        selected.store(&inbox_functions, .release);
        if (bundled_functions.module) |module| _ = windows.kernel32.FreeLibrary(module);
        if (bundled_functions.bundled_path) |path| std.heap.page_allocator.free(path);
        bundled_functions = inbox_functions;
        resolver_once = std.once(initialize);
        live_bundled_hpcons.store(0, .release);
        fallback_banner_pending.store(false, .release);
    }
};

/// Windows PTY creation and management.
const WindowsPty = struct {
    pub const Error = OpenError || GetSizeError || SetSizeError;

    pub const Fd = windows.HANDLE;

    // Process-wide counter for pipe names
    var pipe_name_counter = std.atomic.Value(u32).init(1);

    out_pipe: windows.HANDLE,
    in_pipe: windows.HANDLE,
    out_pipe_pty: ?windows.HANDLE,
    in_pipe_pty: ?windows.HANDLE,
    control: Control,
    size: winsize,

    const Control = union(enum) {
        pseudo_console: PseudoConsole,
        handoff: HandoffControl,
    };

    /// A pseudo console together with the ConPTY implementation that created
    /// it, so a handle is only ever resized or closed by its creator.
    const PseudoConsole = struct {
        handle: windows.exp.HPCON,
        conpty: *const WindowsConPty.Functions,
    };

    const HandoffControl = struct {
        signal: ?windows.HANDLE,
        server_process: windows.HANDLE,
        reference: windows.HANDLE,
        signal_write_mutex: std.Thread.Mutex = .{},
    };

    pub const HandoffHandles = struct {
        /// Read by OpenConsole; noctty writes keystrokes to `in_pipe`.
        input: windows.HANDLE,
        /// Written by OpenConsole; noctty reads application output here.
        output: windows.HANDLE,
    };

    pub const OpenError = error{
        Unexpected,
        /// The bundled ConPTY could not create a pseudo console while other
        /// bundled pseudo consoles are still open in this process, so falling
        /// back to the in-box conhost was refused rather than mixing two
        /// ConPTY implementations. Closing the other terminals allows the
        /// fallback.
        BundledConptyInconsistent,
    };

    fn openPipes(size: winsize) OpenError!Pty {
        var pty: Pty = undefined;

        var pipe_path_buf: [128]u8 = undefined;
        var pipe_path_buf_w: [128]u16 = undefined;
        const pipe_path = std.fmt.bufPrintZ(
            &pipe_path_buf,
            "\\\\.\\pipe\\LOCAL\\ghostty-pty-{d}-{d}",
            .{
                windows.GetCurrentProcessId(),
                pipe_name_counter.fetchAdd(1, .monotonic),
            },
        ) catch unreachable;

        const pipe_path_w_len = std.unicode.utf8ToUtf16Le(
            &pipe_path_buf_w,
            pipe_path,
        ) catch unreachable;
        pipe_path_buf_w[pipe_path_w_len] = 0;
        const pipe_path_w = pipe_path_buf_w[0..pipe_path_w_len :0];

        const security_attributes = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .bInheritHandle = windows.FALSE,
            .lpSecurityDescriptor = null,
        };

        pty.in_pipe = windows.kernel32.CreateNamedPipeW(
            pipe_path_w.ptr,
            windows.PIPE_ACCESS_OUTBOUND |
                windows.exp.FILE_FLAG_FIRST_PIPE_INSTANCE |
                windows.FILE_FLAG_OVERLAPPED,
            windows.PIPE_TYPE_BYTE,
            1,
            4096,
            4096,
            0,
            &security_attributes,
        );
        if (pty.in_pipe == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer _ = windows.CloseHandle(pty.in_pipe);

        var security_attributes_read = security_attributes;
        const in_pipe_pty = windows.kernel32.CreateFileW(
            pipe_path_w.ptr,
            windows.GENERIC_READ,
            0,
            &security_attributes_read,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (in_pipe_pty == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        pty.in_pipe_pty = in_pipe_pty;
        errdefer _ = windows.CloseHandle(in_pipe_pty);

        // The in_pipe needs to be created as a named pipe, since anonymous
        // pipes created with CreatePipe do not support overlapped operations,
        // and the IOCP backend of libxev only uses overlapped operations on files.
        //
        // It would be ideal to use CreatePipe here, so that our pipe isn't
        // visible to any other processes.

        // if (windows.exp.kernel32.CreatePipe(&pty.in_pipe_pty, &pty.in_pipe, null, 0) == 0) {
        //     return windows.unexpectedError(windows.kernel32.GetLastError());
        // }
        // errdefer {
        //     _ = windows.CloseHandle(pty.in_pipe_pty);
        //     _ = windows.CloseHandle(pty.in_pipe);
        // }

        var out_pipe_pty: windows.HANDLE = undefined;
        if (windows.exp.kernel32.CreatePipe(&pty.out_pipe, &out_pipe_pty, null, 0) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        pty.out_pipe_pty = out_pipe_pty;
        errdefer {
            _ = windows.CloseHandle(pty.out_pipe);
            _ = windows.CloseHandle(out_pipe_pty);
        }

        try windows.SetHandleInformation(pty.in_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(in_pipe_pty, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.out_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(out_pipe_pty, windows.HANDLE_FLAG_INHERIT, 0);

        pty.size = size;
        return pty;
    }

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize) OpenError!Pty {
        var pty = try openPipes(size);
        errdefer pty.closePipes();

        var pseudo_console: windows.exp.HPCON = undefined;

        // Selection, creation, and the demotion decision are one critical
        // section. See `WindowsConPty.backend_lock`.
        const Creation = struct {
            pty: *const Pty,
            size: winsize,
            pseudo_console: *windows.exp.HPCON,

            fn attempt(
                self: *const @This(),
                conpty: *const WindowsConPty.Functions,
            ) bool {
                return conpty.create(
                    .{
                        .X = @intCast(self.size.ws_col),
                        .Y = @intCast(self.size.ws_row),
                    },
                    self.pty.in_pipe_pty.?,
                    self.pty.out_pipe_pty.?,
                    0,
                    self.pseudo_console,
                ) == windows.S_OK;
            }
        };
        const creation: Creation = .{
            .pty = &pty,
            .size = size,
            .pseudo_console = &pseudo_console,
        };
        const conpty = WindowsConPty.selectBackend(&creation) catch |err| switch (err) {
            error.CreatePseudoConsoleFailed => return error.Unexpected,
            error.BundledConptyInconsistent => return error.BundledConptyInconsistent,
        };

        pty.control = .{ .pseudo_console = .{
            .handle = pseudo_console,
            .conpty = conpty,
        } };
        return pty;
    }

    /// Build the terminal-owned pipes for an existing OpenConsole session.
    /// All three control handles must already be durable duplicates owned by
    /// the caller. No HPCON exists in this mode.
    pub fn openAdopted(
        size: winsize,
        signal: windows.HANDLE,
        server_process: windows.HANDLE,
        reference: windows.HANDLE,
    ) OpenError!Pty {
        var pty = try openPipes(size);
        pty.control = .{ .handoff = .{
            .signal = signal,
            .server_process = server_process,
            .reference = reference,
        } };
        return pty;
    }

    pub fn pseudoConsole(self: *const Pty) ?windows.exp.HPCON {
        return switch (self.control) {
            .pseudo_console => |pc| pc.handle,
            .handoff => null,
        };
    }

    pub fn isAdopted(self: *const Pty) bool {
        return self.control == .handoff;
    }

    pub fn handoffHandles(self: *const Pty) ?HandoffHandles {
        if (!self.isAdopted()) return null;
        return .{
            .input = self.in_pipe_pty orelse return null,
            .output = self.out_pipe_pty orelse return null,
        };
    }

    /// The COM proxy duplicates these into OpenConsole after the handoff
    /// method returns. The embedding UI posts session adoption to itself, so
    /// this runs only after COM has finished marshaling the returned handles.
    pub fn closeHandoffPipeCopies(self: *Pty) void {
        if (!self.isAdopted()) return;
        if (self.in_pipe_pty) |handle| {
            _ = windows.CloseHandle(handle);
            self.in_pipe_pty = null;
        }
        if (self.out_pipe_pty) |handle| {
            _ = windows.CloseHandle(handle);
            self.out_pipe_pty = null;
        }
    }

    /// Closing the signal pipe asks OpenConsole to begin orderly shutdown.
    pub fn closeAdoptedSignal(self: *Pty) void {
        switch (self.control) {
            .pseudo_console => {},
            .handoff => |*handoff| {
                handoff.signal_write_mutex.lock();
                defer handoff.signal_write_mutex.unlock();
                if (handoff.signal) |handle| {
                    _ = windows.CloseHandle(handle);
                    handoff.signal = null;
                }
            },
        }
    }

    fn closePipes(self: *Pty) void {
        if (self.in_pipe_pty) |handle| _ = windows.CloseHandle(handle);
        _ = windows.CloseHandle(self.in_pipe);
        if (self.out_pipe_pty) |handle| _ = windows.CloseHandle(handle);
        _ = windows.CloseHandle(self.out_pipe);
        self.in_pipe_pty = null;
        self.out_pipe_pty = null;
    }

    pub fn deinit(self: *Pty) void {
        self.closeAdoptedSignal();
        self.closePipes();
        switch (self.control) {
            .pseudo_console => |pc| {
                pc.conpty.close(pc.handle);
                // Only after the close: a zero count promises no live handle.
                if (pc.conpty.source == .bundled) WindowsConPty.releaseBundledHpcon();
            },
            .handoff => |handoff| {
                _ = windows.CloseHandle(handoff.server_process);
                _ = windows.CloseHandle(handoff.reference);
            },
        }
        self.* = undefined;
    }

    pub const GetSizeError = error{};

    /// Return the size of the pty.
    pub fn getSize(self: Pty) GetSizeError!winsize {
        return self.size;
    }

    pub const SetSizeError = error{ResizeFailed};

    pub fn encodeHandoffResize(columns: u16, rows: u16) [6]u8 {
        var packet: [6]u8 = undefined;
        std.mem.writeInt(u16, packet[0..2], 8, .little);
        std.mem.writeInt(u16, packet[2..4], columns, .little);
        std.mem.writeInt(u16, packet[4..6], rows, .little);
        return packet;
    }

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        switch (self.control) {
            .pseudo_console => |pc| {
                const result = pc.conpty.resize(
                    pc.handle,
                    .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
                );
                if (result != windows.S_OK) return error.ResizeFailed;
            },
            .handoff => |*handoff| {
                handoff.signal_write_mutex.lock();
                defer handoff.signal_write_mutex.unlock();
                const signal = handoff.signal orelse return error.ResizeFailed;
                const packet = encodeHandoffResize(size.ws_col, size.ws_row);
                var written: windows.DWORD = 0;
                if (windows.kernel32.WriteFile(signal, &packet, packet.len, &written, null) == 0 or
                    written != packet.len)
                {
                    return error.ResizeFailed;
                }
            },
        }
        self.size = size;
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(_: *WindowsPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};

test "handoff resize writes one exact signal packet" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var signal_read: windows.HANDLE = undefined;
    var signal_write: windows.HANDLE = undefined;
    try std.testing.expect(windows.exp.kernel32.CreatePipe(&signal_read, &signal_write, null, 0) != 0);
    defer _ = windows.CloseHandle(signal_read);
    defer _ = windows.CloseHandle(signal_write);

    var pty: WindowsPty = .{
        .out_pipe = undefined,
        .in_pipe = undefined,
        .out_pipe_pty = null,
        .in_pipe_pty = null,
        .control = .{ .handoff = .{
            .signal = signal_write,
            .server_process = windows.INVALID_HANDLE_VALUE,
            .reference = windows.INVALID_HANDLE_VALUE,
        } },
        .size = .{},
    };
    try pty.setSize(.{ .ws_col = 80, .ws_row = 24 });

    var packet: [6]u8 = undefined;
    var read: windows.DWORD = 0;
    try std.testing.expect(windows.kernel32.ReadFile(signal_read, &packet, packet.len, &read, null) != 0);
    try std.testing.expectEqual(@as(windows.DWORD, packet.len), read);
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x00, 0x50, 0x00, 0x18, 0x00 }, &packet);
}

test "Windows ConPTY resolver selects inbox and default auto backends" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const original_raw = std.process.getEnvVarOwned(
        testing.allocator,
        "NOCTTY_CONPTY",
    ) catch null;
    defer if (original_raw) |value| testing.allocator.free(value);
    const original = if (original_raw) |value|
        try testing.allocator.dupeZ(u8, value)
    else
        null;
    defer if (original) |value| testing.allocator.free(value);
    defer {
        WindowsConPty.resetForTest();
        if (original) |value| {
            _ = internal_os.setenv("NOCTTY_CONPTY", value);
        } else {
            _ = internal_os.unsetenv("NOCTTY_CONPTY");
        }
    }

    WindowsConPty.resetForTest();
    try testing.expectEqual(@as(c_int, 0), internal_os.setenv("NOCTTY_CONPTY", "inbox"));
    try testing.expectEqual(ConPtySource.inbox, conPtyInfo().?.source);
    {
        var inbox_pty = try WindowsPty.open(.{ .ws_row = 24, .ws_col = 80 });
        defer inbox_pty.deinit();
        try inbox_pty.setSize(.{ .ws_row = 40, .ws_col = 120 });
        try testing.expectEqual(@as(u16, 40), (try inbox_pty.getSize()).ws_row);
    }

    WindowsConPty.resetForTest();
    try testing.expectEqual(@as(c_int, 0), internal_os.unsetenv("NOCTTY_CONPTY"));
    try testing.expect(conPtyInfo() != null);
    {
        var auto_pty = try WindowsPty.open(.{ .ws_row = 24, .ws_col = 80 });
        defer auto_pty.deinit();
        try auto_pty.setSize(.{ .ws_row = 50, .ws_col = 100 });
        try testing.expectEqual(@as(u16, 100), (try auto_pty.getSize()).ws_col);
    }
}

/// Install a bundled-looking backend without loading conpty.dll, so the
/// selection bookkeeping can be exercised without creating a pseudo console.
/// The resolver `std.once` is burned first, otherwise the next `functions()`
/// call would overwrite the fake selection with a real resolve.
fn installFakeBundledBackendForTest() void {
    std.debug.assert(builtin.is_test);

    _ = internal_os.setenv("NOCTTY_CONPTY", "inbox");
    _ = conPtyInfo();
    _ = internal_os.unsetenv("NOCTTY_CONPTY");

    WindowsConPty.bundled_functions = .{
        .source = .bundled,
        .create = WindowsConPty.inbox_functions.create,
        .resize = WindowsConPty.inbox_functions.resize,
        .close = WindowsConPty.inbox_functions.close,
    };
    WindowsConPty.selected.store(&WindowsConPty.bundled_functions, .release);
}

test "Windows ConPTY demotion never outruns a live bundled pseudo console" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const original_raw = std.process.getEnvVarOwned(
        testing.allocator,
        "NOCTTY_CONPTY",
    ) catch null;
    defer if (original_raw) |value| testing.allocator.free(value);
    const original = if (original_raw) |value|
        try testing.allocator.dupeZ(u8, value)
    else
        null;
    defer if (original) |value| testing.allocator.free(value);
    defer {
        WindowsConPty.resetForTest();
        if (original) |value| {
            _ = internal_os.setenv("NOCTTY_CONPTY", value);
        } else {
            _ = internal_os.unsetenv("NOCTTY_CONPTY");
        }
    }

    // A creation attempt with an injected outcome: the in-box backend always
    // succeeds, the bundled backend succeeds only for the designated winner.
    const Creation = struct {
        succeeds_on_bundled: bool,
        ready: ?*std.atomic.Value(u32) = null,
        chosen: ?ConPtySource = null,
        failure: ?WindowsConPty.SelectError = null,

        fn attempt(
            self: *const @This(),
            conpty: *const WindowsConPty.Functions,
        ) bool {
            // Widen the window the lock has to close.
            std.Thread.yield() catch {};
            return conpty.source == .inbox or self.succeeds_on_bundled;
        }

        fn run(self: *@This()) void {
            if (self.ready) |ready| {
                _ = ready.fetchAdd(1, .acq_rel);
                while (ready.load(.acquire) < 2) std.atomic.spinLoopHint();
            }
            if (WindowsConPty.selectBackend(self)) |backend| {
                self.chosen = backend.source;
            } else |err| {
                self.failure = err;
            }
        }
    };

    // A bundled success claims the process: a later bundled failure must fail
    // the open rather than demote past the live HPCON and split transports.
    WindowsConPty.resetForTest();
    installFakeBundledBackendForTest();
    var winner: Creation = .{ .succeeds_on_bundled = true };
    winner.run();
    var late: Creation = .{ .succeeds_on_bundled = false };
    late.run();
    try testing.expectEqual(ConPtySource.bundled, winner.chosen.?);
    try testing.expect(late.chosen == null);
    try testing.expectEqual(error.BundledConptyInconsistent, late.failure.?);
    try testing.expectEqual(
        ConPtySource.bundled,
        WindowsConPty.selected.load(.acquire).source,
    );
    try testing.expectEqual(@as(u32, 1), WindowsConPty.live_bundled_hpcons.load(.acquire));

    // Once the winner's pseudo console is closed no live handle remains, so
    // the very same failure now demotes the process instead of refusing.
    WindowsConPty.releaseBundledHpcon();
    try testing.expectEqual(@as(u32, 0), WindowsConPty.live_bundled_hpcons.load(.acquire));
    var after_close: Creation = .{ .succeeds_on_bundled = false };
    after_close.run();
    try testing.expectEqual(ConPtySource.inbox, after_close.chosen.?);
    try testing.expectEqual(
        ConPtySource.inbox,
        WindowsConPty.selected.load(.acquire).source,
    );

    // A bundled failure that gets there first demotes the process, and every
    // later open — including one that would have succeeded on bundled — is
    // resolved to the in-box conhost inside the same critical section.
    WindowsConPty.resetForTest();
    installFakeBundledBackendForTest();
    var first_failure: Creation = .{ .succeeds_on_bundled = false };
    first_failure.run();
    var after_demotion: Creation = .{ .succeeds_on_bundled = true };
    after_demotion.run();
    try testing.expectEqual(ConPtySource.inbox, first_failure.chosen.?);
    try testing.expectEqual(ConPtySource.inbox, after_demotion.chosen.?);
    try testing.expectEqual(@as(u32, 0), WindowsConPty.live_bundled_hpcons.load(.acquire));

    // Racing opens must land on one of those two consistent outcomes; a live
    // bundled HPCON alongside an in-box selection is the state the lock
    // exists to make unreachable.
    WindowsConPty.resetForTest();
    installFakeBundledBackendForTest();
    var ready: std.atomic.Value(u32) = .init(0);
    var racing_success: Creation = .{ .succeeds_on_bundled = true, .ready = &ready };
    var racing_failure: Creation = .{ .succeeds_on_bundled = false, .ready = &ready };
    const success_thread = try std.Thread.spawn(.{}, Creation.run, .{&racing_success});
    const failure_thread = try std.Thread.spawn(.{}, Creation.run, .{&racing_failure});
    success_thread.join();
    failure_thread.join();

    const selection = WindowsConPty.selected.load(.acquire).source;
    if (WindowsConPty.live_bundled_hpcons.load(.acquire) != 0) {
        try testing.expectEqual(ConPtySource.bundled, selection);
        try testing.expectEqual(ConPtySource.bundled, racing_success.chosen.?);
        try testing.expect(racing_failure.chosen == null);
        try testing.expectEqual(error.BundledConptyInconsistent, racing_failure.failure.?);
    } else {
        try testing.expectEqual(ConPtySource.inbox, selection);
        try testing.expectEqual(ConPtySource.inbox, racing_success.chosen.?);
        try testing.expectEqual(ConPtySource.inbox, racing_failure.chosen.?);
    }
}

test "Windows ConPTY live bundled count follows real pseudo console open and close" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const original_raw = std.process.getEnvVarOwned(
        testing.allocator,
        "NOCTTY_CONPTY",
    ) catch null;
    defer if (original_raw) |value| testing.allocator.free(value);
    const original = if (original_raw) |value|
        try testing.allocator.dupeZ(u8, value)
    else
        null;
    defer if (original) |value| testing.allocator.free(value);
    defer {
        WindowsConPty.resetForTest();
        if (original) |value| {
            _ = internal_os.setenv("NOCTTY_CONPTY", value);
        } else {
            _ = internal_os.unsetenv("NOCTTY_CONPTY");
        }
    }

    // The fake bundled backend creates real pseudo consoles through kernel32
    // while reporting as bundled, so `open` and `deinit` exercise the exact
    // counting paths a real conpty.dll would.
    WindowsConPty.resetForTest();
    installFakeBundledBackendForTest();
    try testing.expectEqual(@as(u32, 0), WindowsConPty.live_bundled_hpcons.load(.acquire));

    var first = try WindowsPty.open(.{ .ws_row = 24, .ws_col = 80 });
    try testing.expectEqual(ConPtySource.bundled, first.control.pseudo_console.conpty.source);
    try testing.expectEqual(@as(u32, 1), WindowsConPty.live_bundled_hpcons.load(.acquire));
    var second = try WindowsPty.open(.{ .ws_row = 24, .ws_col = 80 });
    try testing.expectEqual(@as(u32, 2), WindowsConPty.live_bundled_hpcons.load(.acquire));

    first.deinit();
    try testing.expectEqual(@as(u32, 1), WindowsConPty.live_bundled_hpcons.load(.acquire));
    second.deinit();
    try testing.expectEqual(@as(u32, 0), WindowsConPty.live_bundled_hpcons.load(.acquire));

    // An adopted session owns no HPCON and must not touch the count.
    var signal_read: windows.HANDLE = undefined;
    var signal_write: windows.HANDLE = undefined;
    try testing.expect(windows.exp.kernel32.CreatePipe(&signal_read, &signal_write, null, 0) != 0);
    defer _ = windows.CloseHandle(signal_read);
    const duplicate = struct {
        fn handle(source: windows.HANDLE) !windows.HANDLE {
            var result: windows.HANDLE = undefined;
            const current = std.os.windows.GetCurrentProcess();
            if (windows.kernel32.DuplicateHandle(
                current,
                source,
                current,
                &result,
                0,
                std.os.windows.FALSE,
                std.os.windows.DUPLICATE_SAME_ACCESS,
            ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());
            return result;
        }
    }.handle;
    const current = std.os.windows.GetCurrentProcess();
    const server_process = try duplicate(current);
    const reference = try duplicate(current);
    var adopted = try WindowsPty.openAdopted(.{}, signal_write, server_process, reference);
    adopted.deinit();
    try testing.expectEqual(@as(u32, 0), WindowsConPty.live_bundled_hpcons.load(.acquire));
}

test "Windows ConPTY bundled loader rejects a DLL without create symbol" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const Fixture = struct {
        fn moveAside(path: []const u8, backup: []const u8) !bool {
            std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            try std.fs.renameAbsolute(path, backup);
            return true;
        }

        fn restore(path: []const u8, backup: []const u8, moved: bool) void {
            std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.debug.panic("failed to remove ConPTY test fixture: {}", .{err}),
            };
            if (moved) std.fs.renameAbsolute(backup, path) catch |err| {
                std.debug.panic("failed to restore staged ConPTY file: {}", .{err});
            };
        }
    };

    WindowsConPty.resetForTest();
    defer WindowsConPty.resetForTest();

    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
    const conpty_path = try std.fs.path.join(testing.allocator, &.{ exe_dir, "conpty.dll" });
    defer testing.allocator.free(conpty_path);
    const open_console_path = try std.fs.path.join(testing.allocator, &.{ exe_dir, "OpenConsole.exe" });
    defer testing.allocator.free(open_console_path);
    const suffix = try std.fmt.allocPrint(testing.allocator, ".noctty-test-backup-{d}", .{windows.GetCurrentProcessId()});
    defer testing.allocator.free(suffix);
    const conpty_backup = try std.mem.concat(testing.allocator, u8, &.{ conpty_path, suffix });
    defer testing.allocator.free(conpty_backup);
    const open_console_backup = try std.mem.concat(testing.allocator, u8, &.{ open_console_path, suffix });
    defer testing.allocator.free(open_console_backup);

    var conpty_moved = false;
    var open_console_moved = false;
    defer Fixture.restore(open_console_path, open_console_backup, open_console_moved);
    defer Fixture.restore(conpty_path, conpty_backup, conpty_moved);
    conpty_moved = try Fixture.moveAside(conpty_path, conpty_backup);
    open_console_moved = try Fixture.moveAside(open_console_path, open_console_backup);

    const system_root = try std.process.getEnvVarOwned(testing.allocator, "SystemRoot");
    defer testing.allocator.free(system_root);
    const known_bad = try std.fs.path.join(testing.allocator, &.{ system_root, "System32", "version.dll" });
    defer testing.allocator.free(known_bad);
    try std.fs.copyFileAbsolute(known_bad, conpty_path, .{});
    try std.fs.copyFileAbsolute(known_bad, open_console_path, .{});

    try testing.expectError(error.CreateSymbolMissing, WindowsConPty.loadBundled());
}

test {
    const testing = std.testing;
    var ws: winsize = .{
        .ws_row = 50,
        .ws_col = 80,
        .ws_xpixel = 1,
        .ws_ypixel = 1,
    };

    var pty = try Pty.open(ws);
    defer pty.deinit();

    // Initialize size should match what we gave it
    try testing.expectEqual(ws, try pty.getSize());

    // Can set and read new sizes
    ws.ws_row *= 2;
    try pty.setSize(ws);
    try testing.expectEqual(ws, try pty.getSize());

    switch (builtin.os.tag) {
        .freebsd => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/")),
        .linux => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/pts/")),
        .macos => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/")),
        else => try testing.expect(pty.getProcessInfo(.tty_name) == null),
    }
}
