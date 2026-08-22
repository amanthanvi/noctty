const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("os/main.zig");
const windows = internal_os.windows;
const ptypkg = @import("pty.zig");

const begin_marker = "NOCTTY-PROBE-BEGIN";
const middle_marker = "NOCTTY-PROBE-MIDDLE";
const end_marker = "NOCTTY-PROBE-END";
const kitty_apc = "\x1b_Gf=24,s=4,v=1,a=T;Tk9DVFRZS0lUVFkh\x1b\\";
const sixel_dcs = "\x1bPqNOCTTYSIXEL~\x1b\\";
const expected = begin_marker ++ kitty_apc ++ middle_marker ++ sixel_dcs ++ end_marker;

pub fn runChildIfRequested() void {
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
            while (total < expected.len) {
                var written: windows.DWORD = 0;
                if (windows.kernel32.WriteFile(
                    stdout,
                    expected[total..].ptr,
                    @intCast(expected.len - total),
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
            try child_env.put("NOCTTY_CONPTY_TRANSPORT_PROBE_CHILD", "1");

            var pty = try ptypkg.Pty.open(.{
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

            const info = ptypkg.conPtyInfo().?;
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
