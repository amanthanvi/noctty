const std = @import("std");
const builtin = @import("builtin");
const windows = @import("os/main.zig").windows;
const posix = std.posix;
const assert = @import("quirks.zig").inlineAssert;

const log = std.log.scoped(.pty);

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
        pseudo_console: windows.exp.HPCON,
        handoff: HandoffControl,
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

    pub const OpenError = error{Unexpected};

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
        const result = windows.exp.kernel32.CreatePseudoConsole(
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
            pty.in_pipe_pty.?,
            pty.out_pipe_pty.?,
            0,
            &pseudo_console,
        );
        if (result != windows.S_OK) return error.Unexpected;

        pty.control = .{ .pseudo_console = pseudo_console };
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
            .pseudo_console => |handle| handle,
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
            .handoff => |*handoff| if (handoff.signal) |handle| {
                _ = windows.CloseHandle(handle);
                handoff.signal = null;
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
            .pseudo_console => |handle| windows.exp.kernel32.ClosePseudoConsole(handle),
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
            .pseudo_console => |handle| {
                const result = windows.exp.kernel32.ResizePseudoConsole(
                    handle,
                    .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
                );
                if (result != windows.S_OK) return error.ResizeFailed;
            },
            .handoff => |*handoff| {
                const signal = handoff.signal orelse return error.ResizeFailed;
                const packet = encodeHandoffResize(size.ws_col, size.ws_row);
                handoff.signal_write_mutex.lock();
                defer handoff.signal_write_mutex.unlock();
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
