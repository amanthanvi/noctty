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

// The graphics differential below is a separate child mode: it measures
// whether a Kitty graphics APC and a Sixel DCS survive the active ConPTY
// implementation byte for byte, which the round-trip cases above do not
// cover (their alphabet is deliberately escape-free).
const graphics_child_mode = "graphics";
const graphics_run_env_name = "NOCTTY_CONPTY_TRANSPORT_PROBE";
const graphics_begin_marker = "NOCTTY-PROBE-BEGIN";
const graphics_middle_marker = "NOCTTY-PROBE-MIDDLE";
const graphics_end_marker = "NOCTTY-PROBE-END";
const kitty_apc = "\x1b_Gf=24,s=4,v=1,a=T;Tk9DVFRZS0lUVFkh\x1b\\";
const sixel_dcs = "\x1bPqNOCTTYSIXEL~\x1b\\";
const graphics_payload = graphics_begin_marker ++ kitty_apc ++
    graphics_middle_marker ++ sixel_dcs ++ graphics_end_marker;

// The key-input differential below is a third child mode: it measures which
// terminal-to-application key encodings survive the ConPTY input pipe. ConPTY
// parses the bytes we write into INPUT_RECORDs and re-synthesises them for the
// child, so an encoding its input state machine does not know is dropped
// entirely rather than passed through.
const key_input_child_mode = "keyinput";
const key_input_run_env_name = "NOCTTY_CONPTY_KEY_INPUT_PROBE";
const key_input_ready_marker = "NOCTTY-KEYS-READY";
const key_input_begin_marker = "NOCTTY-KEYS-BEGIN";
const key_input_end_marker = "NOCTTY-KEYS-END";

/// Terminating byte the parent writes once every case has been sent. It is
/// never part of a case payload or delimiter.
const key_input_sentinel: u8 = 'Z';

const KeyInputCase = struct {
    name: []const u8,
    /// Bytes the parent writes into the ConPTY input pipe.
    payload: []const u8,
    /// Printable byte written after the payload so the child can tell one
    /// case from the next even when the payload is dropped outright.
    delimiter: u8,
    /// The bytes conhost would hand the application for this key when no
    /// keyboard protocol is negotiated, i.e. what the app sees in plain
    /// conhost. Used to tell a passthrough apart from a rewrite.
    legacy_equivalent: []const u8,
};

/// The encodings noctty can emit for Esc, Ctrl+[, Ctrl+C, Tab and Enter, plus
/// one sequence (CSI A) ConPTY is known to understand, as a control case that
/// proves the input state machine is active.
///
/// A Kitty CSI-u key number is the key's own codepoint, so Ctrl+[ is 91 ('[')
/// with a Ctrl modifier, not 27: `CSI 27;5 u` is Ctrl+Esc and is kept as its
/// own case. `CSI 27;129 u` is the plain Esc noctty writes while Num Lock is
/// on, because the Kitty modifier field carries the lock modifiers
/// (num_lock = 128, reported as bitmask + 1). Both forms were captured from a
/// real Claude Code session in issue #223.
const key_input_cases = [_]KeyInputCase{
    .{ .name = "legacy_esc", .payload = "\x1b", .delimiter = 'A', .legacy_equivalent = "\x1b" },
    .{ .name = "kitty_esc", .payload = "\x1b[27u", .delimiter = 'B', .legacy_equivalent = "\x1b" },
    .{ .name = "kitty_esc_num_lock", .payload = "\x1b[27;129u", .delimiter = 'C', .legacy_equivalent = "\x1b" },
    .{ .name = "kitty_ctrl_esc", .payload = "\x1b[27;5u", .delimiter = 'D', .legacy_equivalent = "\x1b" },
    .{ .name = "kitty_ctrl_bracket", .payload = "\x1b[91;5u", .delimiter = 'E', .legacy_equivalent = "\x1b" },
    .{ .name = "legacy_ctrl_c", .payload = "\x03", .delimiter = 'F', .legacy_equivalent = "\x03" },
    .{ .name = "kitty_ctrl_c", .payload = "\x1b[99;5u", .delimiter = 'G', .legacy_equivalent = "\x03" },
    .{ .name = "legacy_tab", .payload = "\t", .delimiter = 'H', .legacy_equivalent = "\t" },
    .{ .name = "kitty_enter", .payload = "\x1b[13u", .delimiter = 'I', .legacy_equivalent = "\r" },
    .{ .name = "modify_other_keys_esc", .payload = "\x1b[27;5;27~", .delimiter = 'J', .legacy_equivalent = "\x1b" },
    .{ .name = "csi_cursor_up", .payload = "\x1b[A", .delimiter = 'K', .legacy_equivalent = "\x1b[A" },
};

pub fn runChildIfRequested() void {
    if (comptime builtin.os.tag != .windows) return;

    const child = std.process.getEnvVarOwned(
        std.heap.page_allocator,
        child_env_name,
    ) catch return;
    defer std.heap.page_allocator.free(child);
    if (std.mem.eql(u8, child, graphics_child_mode)) {
        const GraphicsChild = struct {
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
                if (SetConsoleMode(stdout, mode | 0x0001 | 0x0004) == 0) {
                    std.process.exit(92);
                }

                var total: usize = 0;
                while (total < graphics_payload.len) {
                    var written: windows.DWORD = 0;
                    if (windows.kernel32.WriteFile(
                        stdout,
                        graphics_payload[total..].ptr,
                        @intCast(graphics_payload.len - total),
                        &written,
                        null,
                    ) == 0 or written == 0) std.process.exit(93);
                    total += written;
                }
                std.process.exit(0);
            }
        };

        GraphicsChild.run();
    }
    if (std.mem.eql(u8, child, key_input_child_mode)) {
        const KeyInputChild = struct {
            const enable_processed_input: windows.DWORD = 0x0001;
            const enable_line_input: windows.DWORD = 0x0002;
            const enable_echo_input: windows.DWORD = 0x0004;
            const enable_virtual_terminal_input: windows.DWORD = 0x0200;
            const enable_processed_output: windows.DWORD = 0x0001;
            const enable_virtual_terminal_processing: windows.DWORD = 0x0004;
            const max_received = 512;

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
                    ) == 0 or written == 0) std.process.exit(83);
                    offset += written;
                }
            }

            fn run() noreturn {
                const stdin = std.fs.File.stdin().handle;
                const stdout = std.fs.File.stdout().handle;

                // Raw VT input: no line editing, no echo, and no processed
                // input so Ctrl+C arrives as a 0x03 byte instead of a console
                // control event. This is the mode a full-screen TUI uses.
                var input_mode: windows.DWORD = 0;
                if (GetConsoleMode(stdin, &input_mode) == 0) std.process.exit(81);
                input_mode |= enable_virtual_terminal_input;
                input_mode &= ~(enable_line_input |
                    enable_echo_input |
                    enable_processed_input);
                if (SetConsoleMode(stdin, input_mode) == 0) std.process.exit(82);

                var output_mode: windows.DWORD = 0;
                if (GetConsoleMode(stdout, &output_mode) == 0) std.process.exit(84);
                if (SetConsoleMode(
                    stdout,
                    output_mode |
                        enable_processed_output |
                        enable_virtual_terminal_processing,
                ) == 0) std.process.exit(85);

                writeAll(stdout, key_input_ready_marker ++ "\r\n");

                var received: [max_received]u8 = undefined;
                var len: usize = 0;
                while (true) {
                    var byte: [1]u8 = undefined;
                    var read: windows.DWORD = 0;
                    if (windows.kernel32.ReadFile(
                        stdin,
                        &byte,
                        1,
                        &read,
                        null,
                    ) == 0 or read != 1) std.process.exit(86);
                    if (byte[0] == key_input_sentinel) break;
                    if (len == received.len) std.process.exit(87);
                    received[len] = byte[0];
                    len += 1;
                }

                writeAll(stdout, key_input_begin_marker);
                const digits = "0123456789abcdef";
                for (received[0..len]) |byte| {
                    const hex = [2]u8{ digits[byte >> 4], digits[byte & 0x0f] };
                    writeAll(stdout, &hex);
                }
                writeAll(stdout, key_input_end_marker ++ "\r\n");
                std.process.exit(0);
            }
        };

        KeyInputChild.run();
    }
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

pub fn runParentIfRequested() !void {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const Probe = struct {
        const Command = @import("Command.zig");
        const wait_timeout: windows.DWORD = 258;

        extern "kernel32" fn GetProcessId(
            process: windows.HANDLE,
        ) callconv(.winapi) windows.DWORD;

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

test "Windows ConPTY transport probe reports APC and DCS survival" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const Probe = struct {
        const Command = @import("Command.zig");
        const timeout_ms = 10_000;
        const quiet_ns = 500 * std.time.ns_per_ms;
        const wait_timeout: windows.DWORD = 258;

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
            pty: *ptypkg.Pty,
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
            try child_env.put(child_env_name, graphics_child_mode);

            var pty = try ptypkg.Pty.open(.{
                .ws_row = 24,
                .ws_col = 200,
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

            const info = ptypkg.conPtyInfo().?;
            const kitty_observed = try between(observed, graphics_begin_marker, graphics_middle_marker);
            const sixel_observed = try between(observed, graphics_middle_marker, graphics_end_marker);
            const kitty = classify(kitty_observed, kitty_apc);
            const sixel = classify(sixel_observed, sixel_dcs);

            std.debug.print("transport-probe source={t}\n", .{info.source});
            printHex("expected_hex", graphics_payload);
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
        graphics_run_env_name,
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;

    try Probe.run();
}
test "Windows ConPTY input transport probe reports key encoding survival" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const Probe = struct {
        const Command = @import("Command.zig");
        const settle_ms = 200;
        const wait_timeout: windows.DWORD = 258;

        const Survival = enum {
            /// The child read exactly the bytes we wrote: ConPTY carried the
            /// encoding through without understanding it.
            passed_through,
            /// ConPTY rewrote the encoding into the legacy bytes.
            rewritten_to_legacy,
            /// The child read something else entirely.
            altered,
            /// The child read nothing at all for this case.
            dropped,
        };

        extern "kernel32" fn GetProcessId(
            process: windows.HANDLE,
        ) callconv(.winapi) windows.DWORD;

        fn classify(
            observed: []const u8,
            payload: []const u8,
            legacy_equivalent: []const u8,
        ) Survival {
            if (observed.len == 0) return .dropped;
            if (std.mem.eql(u8, observed, payload)) return .passed_through;
            if (std.mem.eql(u8, observed, legacy_equivalent)) return .rewritten_to_legacy;
            return .altered;
        }

        fn printHex(label: []const u8, bytes: []const u8) void {
            std.debug.print("{s}=", .{label});
            for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
            std.debug.print("", .{});
        }

        /// Drain whatever the pseudo console has already emitted without
        /// blocking, so the output pipe never backs up mid-run.
        fn pump(
            pty: *ptypkg.Pty,
            output: *std.ArrayList(u8),
        ) !void {
            while (true) {
                var available: windows.DWORD = 0;
                if (windows.exp.kernel32.PeekNamedPipe(
                    pty.out_pipe,
                    null,
                    0,
                    null,
                    &available,
                    null,
                ) == 0) {
                    if (windows.kernel32.GetLastError() == .BROKEN_PIPE) return;
                    return windows.unexpectedError(windows.kernel32.GetLastError());
                }
                if (available == 0) return;
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
                    return error.KeyInputProbeOutputTooLarge;
                }
                try output.appendSlice(std.testing.allocator, buffer[0..read]);
            }
        }

        fn readUntilMarker(
            pty: *ptypkg.Pty,
            output: *std.ArrayList(u8),
            marker: []const u8,
            timeout_ns: u64,
        ) !void {
            var timer = try std.time.Timer.start();
            while (timer.read() < timeout_ns) {
                try pump(pty, output);
                if (std.mem.indexOf(u8, output.items, marker) != null) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            return error.KeyInputProbeReadTimeout;
        }

        fn terminateAndConfirm(process: windows.HANDLE) !void {
            switch (windows.kernel32.WaitForSingleObject(process, 0)) {
                std.os.windows.WAIT_OBJECT_0 => return,
                std.os.windows.WAIT_TIMEOUT => {},
                std.os.windows.WAIT_FAILED => return windows.unexpectedError(
                    windows.kernel32.GetLastError(),
                ),
                else => return error.KeyInputProbeUnexpectedWait,
            }
            if (windows.kernel32.TerminateProcess(process, 0xEE) == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
            if (windows.kernel32.WaitForSingleObject(process, 5000) != 0) {
                return error.KeyInputProbeChildCleanupTimeout;
            }
        }

        fn decodeHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
            if (hex.len % 2 != 0) return error.KeyInputProbeOddHexLength;
            const bytes = try allocator.alloc(u8, hex.len / 2);
            errdefer allocator.free(bytes);
            for (bytes, 0..) |*byte, index| {
                byte.* = try std.fmt.parseInt(u8, hex[index * 2 ..][0..2], 16);
            }
            return bytes;
        }

        fn run() !void {
            const allocator = std.testing.allocator;
            const self_path = try std.fs.selfExePathAlloc(allocator);
            defer allocator.free(self_path);
            const self_path_z = try allocator.dupeZ(u8, self_path);
            defer allocator.free(self_path_z);
            var child_env = try std.process.getEnvMap(allocator);
            defer child_env.deinit();
            try child_env.put(child_env_name, key_input_child_mode);

            var pty = try ptypkg.Pty.open(.{ .ws_row = 25, .ws_col = 200 });
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
            var child_finished = false;
            defer {
                if (!child_finished) terminateAndConfirm(process) catch |err| {
                    std.debug.print("key-input-probe cleanup failed err={}\n", .{err});
                };
                _ = windows.CloseHandle(process);
            }
            std.debug.print("key-input-probe parent_pid={d} child_pid={d}\n", .{
                windows.GetCurrentProcessId(),
                GetProcessId(process),
            });

            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(allocator);
            try readUntilMarker(
                &pty,
                &output,
                key_input_ready_marker,
                10 * std.time.ns_per_s,
            );

            // Each payload is written on its own, then the delimiter is
            // written on its own. ConPTY's input state machine flushes a
            // partial escape at the end of every write, so a lone ESC is not
            // held waiting for the delimiter that follows it.
            for (key_input_cases) |case| {
                try writeFragment(pty.in_pipe, case.payload, 2000);
                std.Thread.sleep(settle_ms * std.time.ns_per_ms);
                try pump(&pty, &output);
                try writeFragment(pty.in_pipe, &[_]u8{case.delimiter}, 2000);
                std.Thread.sleep(settle_ms * std.time.ns_per_ms);
                try pump(&pty, &output);
            }
            try writeFragment(pty.in_pipe, &[_]u8{key_input_sentinel}, 2000);

            try readUntilMarker(
                &pty,
                &output,
                key_input_end_marker,
                10 * std.time.ns_per_s,
            );

            const begin = std.mem.indexOf(u8, output.items, key_input_begin_marker).? +
                key_input_begin_marker.len;
            const end = begin + (std.mem.indexOf(
                u8,
                output.items[begin..],
                key_input_end_marker,
            ) orelse return error.KeyInputProbeEndMarkerMissing);
            const received = try decodeHex(allocator, output.items[begin..end]);
            defer allocator.free(received);

            const info = ptypkg.conPtyInfo().?;
            std.debug.print("key-input-probe source={t}\n", .{info.source});
            printHex("key-input-probe received_hex", received);
            std.debug.print("\n", .{});

            var cursor: usize = 0;
            var failures: usize = 0;
            for (key_input_cases) |case| {
                const relative = std.mem.indexOfScalar(
                    u8,
                    received[cursor..],
                    case.delimiter,
                ) orelse return error.KeyInputProbeDelimiterMissing;
                const observed = received[cursor..][0..relative];
                cursor += relative + 1;
                const survival = classify(observed, case.payload, case.legacy_equivalent);
                std.debug.print("key-input-probe case={s} verdict={t} ", .{
                    case.name,
                    survival,
                });
                printHex("wrote_hex", case.payload);
                std.debug.print(" ", .{});
                printHex("legacy_hex", case.legacy_equivalent);
                std.debug.print(" ", .{});
                printHex("observed_hex", observed);
                std.debug.print("\n", .{});
                // Every case must reach the child byte for byte. ConPTY parses
                // our bytes into INPUT_RECORDs and re-synthesises them, so a
                // dropped or rewritten case is a transport limit that noctty's
                // key encoder has to work around.
                if (survival != .passed_through) failures += 1;
            }
            // Nothing may follow the last delimiter. A trailing byte means the
            // child read something no case accounts for, which would otherwise
            // pass silently.
            try std.testing.expectEqual(received.len, cursor);
            try std.testing.expectEqual(@as(usize, 0), failures);

            try readUntilMarker(&pty, &output, key_input_end_marker, std.time.ns_per_s);
            switch (windows.kernel32.WaitForSingleObject(process, 5000)) {
                std.os.windows.WAIT_OBJECT_0 => child_finished = true,
                else => {},
            }
        }
    };

    const enabled = std.process.getEnvVarOwned(
        std.testing.allocator,
        key_input_run_env_name,
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;

    try Probe.run();
}
