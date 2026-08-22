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
    var bundled_hpc_created = std.atomic.Value(bool).init(false);
    var fallback_banner_pending = std.atomic.Value(bool).init(false);

    fn functions() *const Functions {
        resolver_once.call();
        return selected.load(.acquire);
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
        bundled_hpc_created.store(false, .release);
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
    out_pipe_pty: windows.HANDLE,
    in_pipe_pty: windows.HANDLE,
    pseudo_console: windows.exp.HPCON,
    conpty: *const WindowsConPty.Functions,
    size: winsize,

    pub const OpenError = error{Unexpected};

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize) OpenError!Pty {
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
        pty.in_pipe_pty = windows.kernel32.CreateFileW(
            pipe_path_w.ptr,
            windows.GENERIC_READ,
            0,
            &security_attributes_read,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (pty.in_pipe_pty == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer _ = windows.CloseHandle(pty.in_pipe_pty);

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

        if (windows.exp.kernel32.CreatePipe(&pty.out_pipe, &pty.out_pipe_pty, null, 0) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer {
            _ = windows.CloseHandle(pty.out_pipe);
            _ = windows.CloseHandle(pty.out_pipe_pty);
        }

        try windows.SetHandleInformation(pty.in_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.in_pipe_pty, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.out_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(pty.out_pipe_pty, windows.HANDLE_FLAG_INHERIT, 0);

        var conpty = WindowsConPty.functions();
        const source = conpty.source;
        var result = conpty.create(
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
            pty.in_pipe_pty,
            pty.out_pipe_pty,
            0,
            &pty.pseudo_console,
        );
        if (result == windows.S_OK and source == .bundled) {
            WindowsConPty.bundled_hpc_created.store(true, .release);
        } else if (result != windows.S_OK and
            source == .bundled and
            !WindowsConPty.bundled_hpc_created.load(.acquire))
        {
            if (WindowsConPty.selected.cmpxchgStrong(
                conpty,
                &WindowsConPty.inbox_functions,
                .acq_rel,
                .acquire,
            ) == null) {
                log.warn(
                    "bundled ConPTY failed to create a pseudo console; using the in-box conhost — Kitty graphics (APC) and Sixel (DCS) passthrough may be silently stripped on this Windows build",
                    .{},
                );
                WindowsConPty.signalFallbackBanner();
            }
            conpty = &WindowsConPty.inbox_functions;
            result = conpty.create(
                .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
                pty.in_pipe_pty,
                pty.out_pipe_pty,
                0,
                &pty.pseudo_console,
            );
        }
        if (result != windows.S_OK) return error.Unexpected;

        pty.conpty = conpty;
        pty.size = size;
        return pty;
    }

    pub fn deinit(self: *Pty) void {
        _ = windows.CloseHandle(self.in_pipe_pty);
        _ = windows.CloseHandle(self.in_pipe);
        _ = windows.CloseHandle(self.out_pipe_pty);
        _ = windows.CloseHandle(self.out_pipe);
        self.conpty.close(self.pseudo_console);
        self.* = undefined;
    }

    pub const GetSizeError = error{};

    /// Return the size of the pty.
    pub fn getSize(self: Pty) GetSizeError!winsize {
        return self.size;
    }

    pub const SetSizeError = error{ResizeFailed};

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        const result = self.conpty.resize(
            self.pseudo_console,
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
        );

        if (result != windows.S_OK) return error.ResizeFailed;
        self.size = size;
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(_: *WindowsPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};

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
