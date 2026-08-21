const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("os/main.zig");
const windows = internal_os.windows;
const posix = std.posix;
const assert = @import("quirks.zig").inlineAssert;

const log = std.log.scoped(.pty);

const conpty_transport_probe_begin_marker = "NOCTTY-PROBE-BEGIN";
const conpty_transport_probe_middle_marker = "NOCTTY-PROBE-MIDDLE";
const conpty_transport_probe_end_marker = "NOCTTY-PROBE-END";
const conpty_transport_probe_kitty_apc = "\x1b_Gf=24,s=4,v=1,a=T;Tk9DVFRZS0lUVFkh\x1b\\";
const conpty_transport_probe_sixel_dcs = "\x1bPqNOCTTYSIXEL~\x1b\\";
const conpty_transport_probe_expected = conpty_transport_probe_begin_marker ++
    conpty_transport_probe_kitty_apc ++
    conpty_transport_probe_middle_marker ++
    conpty_transport_probe_sixel_dcs ++
    conpty_transport_probe_end_marker;

pub fn runConPtyTransportProbeChildIfRequested() void {
    if (comptime builtin.os.tag != .windows) return;

    const child = std.process.getEnvVarOwned(
        std.heap.page_allocator,
        "NOCTTY_CONPTY_TRANSPORT_PROBE_CHILD",
    ) catch return;
    defer std.heap.page_allocator.free(child);
    if (!std.mem.eql(u8, child, "1")) return;

    const Child = struct {
        extern "kernel32" fn GetConsoleMode(
            console: windows.HANDLE,
            mode: *windows.DWORD,
        ) callconv(.winapi) c_int;
        extern "kernel32" fn SetConsoleMode(
            console: windows.HANDLE,
            mode: windows.DWORD,
        ) callconv(.winapi) c_int;

        fn run() noreturn {
            const stdout = std.fs.File.stdout().handle;
            var mode: windows.DWORD = 0;
            if (GetConsoleMode(stdout, &mode) == 0) std.process.exit(91);
            if (SetConsoleMode(stdout, mode | 0x0001 | 0x0004) == 0) std.process.exit(92);

            var total: usize = 0;
            while (total < conpty_transport_probe_expected.len) {
                var written: windows.DWORD = 0;
                if (windows.kernel32.WriteFile(
                    stdout,
                    conpty_transport_probe_expected[total..].ptr,
                    @intCast(conpty_transport_probe_expected.len - total),
                    &written,
                    null,
                ) == 0 or written == 0) std.process.exit(93);
                total += written;
            }
            std.process.exit(0);
        }
    };

    Child.run();
}

test "Windows ConPTY transport probe child dispatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    runConPtyTransportProbeChildIfRequested();
}

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

    var resolved: ?Functions = null;
    var resolver_once = std.once(initialize);
    var bundled_hpc_created = std.atomic.Value(bool).init(false);

    fn functions() *const Functions {
        resolver_once.call();
        return &resolved.?;
    }

    fn initialize() void {
        resolved = resolve();
    }

    fn resolve() Functions {
        if (forceInbox()) {
            log.warn(
                "bundled ConPTY disabled by NOCTTY_CONPTY=inbox; using the in-box conhost — Kitty graphics (APC) and Sixel (DCS) passthrough may be silently stripped on this Windows build",
                .{},
            );
        } else {
            if (loadBundled()) |bundled| {
                log.info("using bundled ConPTY: {s}", .{bundled.bundled_path.?});
                return bundled;
            } else |err| {
                const reason = switch (err) {
                    error.PathUnavailable => "bundled ConPTY path could not be resolved",
                    error.NotFound => "bundled ConPTY not found",
                    error.LoadFailed => "bundled ConPTY failed to load",
                    error.OpenConsoleMissing => "bundled ConPTY is missing OpenConsole.exe",
                    error.CreateSymbolMissing => "bundled ConPTY is missing CreatePseudoConsole",
                    error.ResizeSymbolMissing => "bundled ConPTY is missing ResizePseudoConsole",
                    error.CloseSymbolMissing => "bundled ConPTY is missing ClosePseudoConsole",
                };
                log.warn(
                    "{s}; using the in-box conhost — Kitty graphics (APC) and Sixel (DCS) passthrough may be silently stripped on this Windows build",
                    .{reason},
                );
            }
        }

        return .{
            .source = .inbox,
            .create = &windows.exp.kernel32.CreatePseudoConsole,
            .resize = &windows.exp.kernel32.ResizePseudoConsole,
            .close = &windows.exp.kernel32.ClosePseudoConsole,
        };
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
        std.fs.accessAbsolute(open_console_path, .{}) catch
            return error.OpenConsoleMissing;

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

    fn resetForTest() void {
        std.debug.assert(builtin.is_test);
        // No live HPCON may cross this reset or its module provenance would change.

        if (resolved) |value| {
            if (value.module) |module| _ = windows.kernel32.FreeLibrary(module);
            if (value.bundled_path) |path| std.heap.page_allocator.free(path);
        }
        resolved = null;
        resolver_once = std.once(initialize);
        bundled_hpc_created.store(false, .release);
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

        const conpty = WindowsConPty.functions();
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
            log.warn(
                "bundled ConPTY failed to create a pseudo console; using the in-box conhost — Kitty graphics (APC) and Sixel (DCS) passthrough may be silently stripped on this Windows build",
                .{},
            );
            WindowsConPty.resolved.?.source = .inbox;
            WindowsConPty.resolved.?.create = &windows.exp.kernel32.CreatePseudoConsole;
            WindowsConPty.resolved.?.resize = &windows.exp.kernel32.ResizePseudoConsole;
            WindowsConPty.resolved.?.close = &windows.exp.kernel32.ClosePseudoConsole;
            result = windows.exp.kernel32.CreatePseudoConsole(
                .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
                pty.in_pipe_pty,
                pty.out_pipe_pty,
                0,
                &pty.pseudo_console,
            );
        }
        if (result != windows.S_OK) return error.Unexpected;

        pty.size = size;
        return pty;
    }

    pub fn deinit(self: *Pty) void {
        _ = windows.CloseHandle(self.in_pipe_pty);
        _ = windows.CloseHandle(self.in_pipe);
        _ = windows.CloseHandle(self.out_pipe_pty);
        _ = windows.CloseHandle(self.out_pipe);
        WindowsConPty.functions().close(self.pseudo_console);
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
        const result = WindowsConPty.functions().resize(
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

test "Windows ConPTY transport probe reports APC and DCS survival" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const Probe = struct {
        const Command = @import("Command.zig");
        const timeout_ms = 10_000;
        const quiet_ns = 500 * std.time.ns_per_ms;
        const wait_timeout: windows.DWORD = 258;
        const begin_marker = conpty_transport_probe_begin_marker;
        const middle_marker = conpty_transport_probe_middle_marker;
        const end_marker = conpty_transport_probe_end_marker;
        const kitty_apc = conpty_transport_probe_kitty_apc;
        const sixel_dcs = conpty_transport_probe_sixel_dcs;
        const expected = conpty_transport_probe_expected;

        const Survival = enum {
            byte_exact,
            altered,
            dropped,
        };

        extern "kernel32" fn GetProcessId(
            process: windows.HANDLE,
        ) callconv(.winapi) windows.DWORD;

        fn classify(observed: []const u8, sequence: []const u8) Survival {
            if (std.mem.eql(u8, observed, sequence)) return .byte_exact;
            if (observed.len == 0) return .dropped;
            return .altered;
        }

        fn between(
            observed: []const u8,
            start_marker: []const u8,
            stop_marker: []const u8,
        ) ![]const u8 {
            const start_offset = std.mem.indexOf(u8, observed, start_marker) orelse
                return error.TransportProbeStartMarkerMissing;
            const start = start_offset + start_marker.len;
            const relative_end = std.mem.indexOf(u8, observed[start..], stop_marker) orelse
                return error.TransportProbeEndMarkerMissing;
            return observed[start .. start + relative_end];
        }

        fn printHex(label: []const u8, bytes: []const u8) void {
            std.debug.print("transport-probe {s}=", .{label});
            for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
            std.debug.print("\n", .{});
        }

        fn terminateAndConfirm(process: windows.HANDLE) !void {
            const terminate_error = if (windows.kernel32.TerminateProcess(process, 1) == 0)
                windows.kernel32.GetLastError()
            else
                null;
            const final_wait = windows.kernel32.WaitForSingleObject(process, windows.INFINITE);
            if (final_wait == windows.WAIT_FAILED) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
            if (final_wait != 0) return error.TransportProbeUnexpectedFinalWaitResult;
            if (terminate_error) |err| return windows.unexpectedError(err);
        }

        fn readOutput(
            pty: *WindowsPty,
            process: windows.HANDLE,
            buffer: []u8,
        ) ![]const u8 {
            var total: usize = 0;
            const process_deadline = std.time.nanoTimestamp() + (timeout_ms * std.time.ns_per_ms);
            var process_signaled = false;
            var quiet_since: i128 = 0;

            while (true) {
                var available: windows.DWORD = 0;
                if (windows.exp.kernel32.PeekNamedPipe(
                    pty.out_pipe,
                    null,
                    0,
                    null,
                    &available,
                    null,
                ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

                if (available > 0) {
                    if (total == buffer.len) return error.TransportProbeOutputTooLarge;
                    const read_len = @min(@as(usize, available), buffer.len - total);
                    var read: windows.DWORD = 0;
                    if (windows.kernel32.ReadFile(
                        pty.out_pipe,
                        buffer[total..][0..read_len].ptr,
                        @intCast(read_len),
                        &read,
                        null,
                    ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());
                    total += read;
                    if (process_signaled) quiet_since = std.time.nanoTimestamp();
                }

                const wait_result = windows.kernel32.WaitForSingleObject(process, 0);
                if (wait_result == 0) {
                    if (!process_signaled) {
                        process_signaled = true;
                        quiet_since = std.time.nanoTimestamp();
                    }
                    if (available == 0 and
                        std.time.nanoTimestamp() - quiet_since >= quiet_ns)
                    {
                        return buffer[0..total];
                    }
                } else if (wait_result == windows.WAIT_FAILED) {
                    return windows.unexpectedError(windows.kernel32.GetLastError());
                } else if (wait_result != wait_timeout) {
                    return error.TransportProbeUnexpectedWaitResult;
                }
                if (!process_signaled and std.time.nanoTimestamp() >= process_deadline) {
                    return error.TransportProbeChildTimedOut;
                }
                if (available == 0) std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        fn run() !void {
            const allocator = std.testing.allocator;
            std.debug.print("transport-probe parent_pid={d}\n", .{windows.GetCurrentProcessId()});
            const self_path = try std.fs.selfExePathAlloc(allocator);
            defer allocator.free(self_path);
            const self_path_z = try allocator.dupeZ(u8, self_path);
            defer allocator.free(self_path_z);
            var child_env = try std.process.getEnvMap(allocator);
            defer child_env.deinit();
            try child_env.put("NOCTTY_CONPTY_TRANSPORT_PROBE_CHILD", "1");

            var pty = try WindowsPty.open(.{
                .ws_row = 24,
                .ws_col = 200,
            });
            defer pty.deinit();

            var command: Command = .{
                .path = self_path_z,
                .args = &.{self_path_z},
                .env = &child_env,
                .pseudo_console = pty.pseudo_console,
                .os_pre_exec = null,
                .rt_pre_exec = null,
                .rt_post_fork = null,
                .rt_pre_exec_info = undefined,
                .rt_post_fork_info = undefined,
            };
            try command.start(std.testing.allocator);
            const process = command.pid.?;
            defer _ = windows.CloseHandle(process);

            const child_pid = GetProcessId(process);
            std.debug.print("transport-probe child_pid={d}\n", .{child_pid});

            var observed_buffer: [64 * 1024]u8 = undefined;
            const observed = readOutput(&pty, process, &observed_buffer) catch |err| {
                try terminateAndConfirm(process);
                return err;
            };

            var exit_code: windows.DWORD = undefined;
            if (windows.kernel32.GetExitCodeProcess(process, &exit_code) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
            try std.testing.expectEqual(@as(windows.DWORD, 0), exit_code);

            const info = conPtyInfo().?;
            const kitty_observed = try between(observed, begin_marker, middle_marker);
            const sixel_observed = try between(observed, middle_marker, end_marker);
            const kitty = classify(kitty_observed, kitty_apc);
            const sixel = classify(sixel_observed, sixel_dcs);

            std.debug.print("transport-probe source={t}\n", .{info.source});
            printHex("expected_hex", expected);
            printHex("observed_hex", observed);
            printHex("kitty_expected_hex", kitty_apc);
            printHex("kitty_observed_hex", kitty_observed);
            std.debug.print("transport-probe kitty_apc={t}\n", .{kitty});
            printHex("sixel_expected_hex", sixel_dcs);
            printHex("sixel_observed_hex", sixel_observed);
            std.debug.print("transport-probe sixel_dcs={t}\n", .{sixel});
        }
    };

    const enabled = std.process.getEnvVarOwned(
        std.testing.allocator,
        "NOCTTY_CONPTY_TRANSPORT_PROBE",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;

    try Probe.run();
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
