const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("os/main.zig");
const windows = internal_os.windows;
const ptypkg = @import("pty.zig");

const child_env_name = "NOCTTY_CONPTY_TRANSPORT_PROBE_CHILD";
const run_env_name = "NOCTTY_RUN_CONPTY_TRANSPORT_TEST";
const ready_marker = "NOCTTY:READY";
const case_count = 24;
const max_payload_len = 24;
const max_output_bytes = 64 * 1024;
const input_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
    "abcdefghijklmnopqrstuvwxyz" ++
    "0123456789._-";

pub fn runChildIfRequested() void {
    if (comptime builtin.os.tag != .windows) return;

    const child = std.process.getEnvVarOwned(
        std.heap.page_allocator,
        child_env_name,
    ) catch return;
    defer std.heap.page_allocator.free(child);
    if (!std.mem.eql(u8, child, "1")) return;

    const Child = struct {
        const enable_processed_input: windows.DWORD = 0x0001;
        const enable_line_input: windows.DWORD = 0x0002;
        const enable_echo_input: windows.DWORD = 0x0004;
        const enable_virtual_terminal_input: windows.DWORD = 0x0200;
        const enable_processed_output: windows.DWORD = 0x0001;
        const enable_virtual_terminal_processing: windows.DWORD = 0x0004;

        extern "kernel32" fn GetConsoleMode(
            console: windows.HANDLE,
            mode: *windows.DWORD,
        ) callconv(.winapi) c_int;
        extern "kernel32" fn SetConsoleMode(
            console: windows.HANDLE,
            mode: windows.DWORD,
        ) callconv(.winapi) c_int;

        fn writeAll(handle: windows.HANDLE, bytes: []const u8) void {
            var offset: usize = 0;
            while (offset < bytes.len) {
                var written: windows.DWORD = 0;
                if (windows.kernel32.WriteFile(
                    handle,
                    bytes[offset..].ptr,
                    @intCast(bytes.len - offset),
                    &written,
                    null,
                ) == 0 or written == 0) std.process.exit(93);
                offset += written;
            }
        }

        fn readLine(handle: windows.HANDLE, buffer: []u8) []const u8 {
            var len: usize = 0;
            while (true) {
                var byte: [1]u8 = undefined;
                var read: windows.DWORD = 0;
                if (windows.kernel32.ReadFile(
                    handle,
                    &byte,
                    1,
                    &read,
                    null,
                ) == 0 or read != 1) std.process.exit(94);
                switch (byte[0]) {
                    '\r' => return buffer[0..len],
                    '\n' => continue,
                    else => {
                        if (len == buffer.len) std.process.exit(95);
                        buffer[len] = byte[0];
                        len += 1;
                    },
                }
            }
        }

        fn run() noreturn {
            const stdin = std.fs.File.stdin().handle;
            const stdout = std.fs.File.stdout().handle;

            var input_mode: windows.DWORD = 0;
            if (GetConsoleMode(stdin, &input_mode) == 0) std.process.exit(91);
            input_mode |= enable_processed_input;
            input_mode &= ~(enable_line_input |
                enable_echo_input |
                enable_virtual_terminal_input);
            if (SetConsoleMode(stdin, input_mode) == 0) std.process.exit(92);

            var output_mode: windows.DWORD = 0;
            if (GetConsoleMode(stdout, &output_mode) == 0) std.process.exit(96);
            if (SetConsoleMode(
                stdout,
                output_mode |
                    enable_processed_output |
                    enable_virtual_terminal_processing,
            ) == 0) std.process.exit(97);

            writeAll(stdout, ready_marker ++ "\r\n");
            for (0..case_count) |case_index| {
                var payload: [max_payload_len]u8 = undefined;
                const line = readLine(stdin, &payload);
                var response: [64]u8 = undefined;
                const marker = std.fmt.bufPrint(
                    &response,
                    "NOCTTY:{d}:{s}\r\n",
                    .{ case_index, line },
                ) catch std.process.exit(98);
                writeAll(stdout, marker);
            }
            std.process.exit(0);
        }
    };

    Child.run();
}

pub fn runParentIfRequested() !void {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const Probe = struct {
        const Command = @import("Command.zig");
        const wait_timeout: windows.DWORD = 258;

        extern "kernel32" fn GetProcessId(
            process: windows.HANDLE,
        ) callconv(.winapi) windows.DWORD;

        fn cancelAndDrainWrite(
            pipe: windows.HANDLE,
            overlapped: *std.os.windows.OVERLAPPED,
        ) !void {
            var cancel_error: ?std.os.windows.Win32Error = null;
            if (std.os.windows.kernel32.CancelIoEx(pipe, overlapped) == 0) {
                const err = std.os.windows.kernel32.GetLastError();
                if (err != .NOT_FOUND) cancel_error = err;
            }

            var ignored: windows.DWORD = 0;
            if (std.os.windows.kernel32.GetOverlappedResult(
                pipe,
                overlapped,
                &ignored,
                windows.TRUE,
            ) == 0) {
                const result_error = std.os.windows.kernel32.GetLastError();
                if (result_error != .OPERATION_ABORTED) {
                    return windows.unexpectedError(result_error);
                }
            }
            if (cancel_error) |err| return windows.unexpectedError(err);
        }

        fn writeFragment(
            pipe: windows.HANDLE,
            bytes: []const u8,
            timeout_ms: windows.DWORD,
        ) !void {
            const event = try std.os.windows.CreateEventEx(
                null,
                "",
                0,
                std.os.windows.EVENT_ALL_ACCESS,
            );
            defer _ = windows.CloseHandle(event);

            var overlapped: std.os.windows.OVERLAPPED = .{
                .Internal = 0,
                .InternalHigh = 0,
                .DUMMYUNIONNAME = .{ .DUMMYSTRUCTNAME = .{
                    .Offset = 0,
                    .OffsetHigh = 0,
                } },
                .hEvent = event,
            };
            const write_result = std.os.windows.kernel32.WriteFile(
                pipe,
                bytes.ptr,
                @intCast(bytes.len),
                null,
                &overlapped,
            );
            if (write_result == 0) {
                const write_error = std.os.windows.kernel32.GetLastError();
                if (write_error != .IO_PENDING) return windows.unexpectedError(write_error);

                switch (std.os.windows.kernel32.WaitForSingleObject(event, timeout_ms)) {
                    std.os.windows.WAIT_OBJECT_0 => {},
                    std.os.windows.WAIT_TIMEOUT => {
                        try cancelAndDrainWrite(pipe, &overlapped);
                        return error.ConptyWriteTimeout;
                    },
                    std.os.windows.WAIT_FAILED => {
                        const wait_error = std.os.windows.kernel32.GetLastError();
                        try cancelAndDrainWrite(pipe, &overlapped);
                        return windows.unexpectedError(wait_error);
                    },
                    else => {
                        try cancelAndDrainWrite(pipe, &overlapped);
                        return error.UnexpectedConptyWriteWait;
                    },
                }
            }
            const written = try std.os.windows.GetOverlappedResult(pipe, &overlapped, false);
            if (written != bytes.len) return error.ShortConptyWrite;
        }

        fn readUntil(
            pty: *ptypkg.Pty,
            process: windows.HANDLE,
            output: *std.ArrayList(u8),
            marker: []const u8,
            require_exit: bool,
            timeout_ns: u64,
        ) !void {
            var timer = try std.time.Timer.start();
            var process_exited = false;
            while (timer.read() < timeout_ns) {
                var available: windows.DWORD = 0;
                if (windows.exp.kernel32.PeekNamedPipe(
                    pty.out_pipe,
                    null,
                    0,
                    null,
                    &available,
                    null,
                ) == 0) {
                    if (windows.kernel32.GetLastError() == .BROKEN_PIPE) {
                        if (std.mem.indexOf(u8, output.items, marker) == null) {
                            return error.ConptyMissingMarker;
                        }
                        if (!require_exit or process_exited) return;
                    } else {
                        return windows.unexpectedError(windows.kernel32.GetLastError());
                    }
                } else if (available > 0) {
                    var buffer: [1024]u8 = undefined;
                    var read: windows.DWORD = 0;
                    if (windows.kernel32.ReadFile(
                        pty.out_pipe,
                        &buffer,
                        @min(@as(windows.DWORD, buffer.len), available),
                        &read,
                        null,
                    ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());
                    if (output.items.len + read > max_output_bytes) {
                        return error.ConptyOutputLimitExceeded;
                    }
                    try output.appendSlice(std.testing.allocator, buffer[0..read]);
                }

                switch (windows.kernel32.WaitForSingleObject(process, 0)) {
                    std.os.windows.WAIT_OBJECT_0 => process_exited = true,
                    std.os.windows.WAIT_TIMEOUT => {},
                    std.os.windows.WAIT_FAILED => return windows.unexpectedError(
                        windows.kernel32.GetLastError(),
                    ),
                    else => return error.UnexpectedConptyProcessWait,
                }
                if ((!require_exit or process_exited) and
                    std.mem.indexOf(u8, output.items, marker) != null) return;
                if (available == 0) std.Thread.sleep(5 * std.time.ns_per_ms);
            }
            return error.ConptyReadTimeout;
        }

        fn terminateAndConfirm(process: windows.HANDLE) !void {
            switch (windows.kernel32.WaitForSingleObject(process, 0)) {
                std.os.windows.WAIT_OBJECT_0 => return,
                std.os.windows.WAIT_TIMEOUT => {},
                std.os.windows.WAIT_FAILED => return windows.unexpectedError(
                    windows.kernel32.GetLastError(),
                ),
                else => return error.UnexpectedConptyProcessWait,
            }
            if (windows.kernel32.TerminateProcess(process, 0xEE) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
            switch (windows.kernel32.WaitForSingleObject(process, 5000)) {
                std.os.windows.WAIT_OBJECT_0 => {},
                std.os.windows.WAIT_TIMEOUT => return error.ConptyChildCleanupTimeout,
                std.os.windows.WAIT_FAILED => return windows.unexpectedError(
                    windows.kernel32.GetLastError(),
                ),
                else => return error.UnexpectedConptyProcessWait,
            }
        }

        fn run() !usize {
            const allocator = std.testing.allocator;
            std.debug.print("ConPTY transport parent_pid={d}\n", .{
                windows.GetCurrentProcessId(),
            });
            const self_path = try std.fs.selfExePathAlloc(allocator);
            defer allocator.free(self_path);
            const self_path_z = try allocator.dupeZ(u8, self_path);
            defer allocator.free(self_path_z);
            var child_env = try std.process.getEnvMap(allocator);
            defer child_env.deinit();
            try child_env.put(child_env_name, "1");

            var pty = try ptypkg.Pty.open(.{
                .ws_row = 25,
                .ws_col = 80,
            });
            defer pty.deinit();

            var command: Command = .{
                .path = self_path_z,
                .args = &.{self_path_z},
                .env = &child_env,
                .pseudo_console = pty.pseudoConsole().?,
                .os_pre_exec = null,
                .rt_pre_exec = null,
                .rt_post_fork = null,
                .rt_pre_exec_info = undefined,
                .rt_post_fork_info = undefined,
            };
            try command.start(allocator);
            const process = command.pid.?;
            var child_exited = false;
            defer {
                if (!child_exited) terminateAndConfirm(process) catch |err| {
                    std.debug.print("ConPTY exact child cleanup failed err={}\n", .{err});
                };
                _ = windows.CloseHandle(process);
            }
            const child_pid = GetProcessId(process);
            try std.testing.expect(child_pid != 0);
            std.debug.print("ConPTY transport child_pid={d}\n", .{child_pid});

            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(allocator);
            try readUntil(
                &pty,
                process,
                &output,
                ready_marker,
                false,
                5 * std.time.ns_per_s,
            );

            var expected_markers: [case_count][]u8 = undefined;
            var expected_count: usize = 0;
            defer for (expected_markers[0..expected_count]) |marker| allocator.free(marker);
            var prng = std.Random.DefaultPrng.init(0x3E79_E45A_6F18_02CD);
            const random = prng.random();
            for (0..case_count) |case_index| {
                var payload: [max_payload_len]u8 = undefined;
                const payload_len = 1 + random.uintLessThan(usize, payload.len);
                for (payload[0..payload_len]) |*byte| {
                    byte.* = input_alphabet[random.uintLessThan(usize, input_alphabet.len)];
                }
                expected_markers[expected_count] = try std.fmt.allocPrint(
                    allocator,
                    "NOCTTY:{d}:{s}",
                    .{ case_index, payload[0..payload_len] },
                );
                expected_count += 1;

                var line: [max_payload_len + 1]u8 = undefined;
                @memcpy(line[0..payload_len], payload[0..payload_len]);
                line[payload_len] = '\r';
                var offset: usize = 0;
                while (offset < payload_len + 1) {
                    const fragment_len = @min(
                        payload_len + 1 - offset,
                        1 + random.uintLessThan(usize, 7),
                    );
                    try writeFragment(
                        pty.in_pipe,
                        line[offset..][0..fragment_len],
                        2000,
                    );
                    offset += fragment_len;
                }
            }

            try readUntil(
                &pty,
                process,
                &output,
                expected_markers[expected_count - 1],
                true,
                15 * std.time.ns_per_s,
            );
            child_exited = true;
            for (expected_markers[0..expected_count]) |marker| {
                try std.testing.expect(std.mem.indexOf(u8, output.items, marker) != null);
            }

            var exit_code: windows.DWORD = undefined;
            if (windows.kernel32.GetExitCodeProcess(process, &exit_code) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
            try std.testing.expectEqual(@as(windows.DWORD, 0), exit_code);
            return expected_count;
        }
    };

    const enabled = std.process.getEnvVarOwned(
        std.testing.allocator,
        run_env_name,
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return;

    std.debug.print("ConPTY transport execution=started expected_round_trips={d}\n", .{
        case_count,
    });
    const completed = try Probe.run();
    try std.testing.expectEqual(@as(usize, case_count), completed);
    std.debug.print("ConPTY transport execution=complete round_trips={d}\n", .{
        completed,
    });
}
