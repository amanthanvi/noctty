//! Single-instance IPC transport, authentication, forwarding and server dispatch.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const log = std.log.scoped(.win32);
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");
const cli_args = @import("../../cli/args.zig");
const configpkg = @import("../../config.zig");
const homedir = @import("../../os/homedir.zig");
const win32 = @import("../win32.zig");
const App = win32.App;
const win32_ipc = @import("../win32_ipc.zig");
const win32_elevation = @import("../win32_elevation.zig");
const win32_paste_protection = @import("../win32_paste_protection.zig");
const win32_toast_activation = @import("../win32_toast_activation.zig");
const c = @import("consts.zig");
const sys = @import("sys.zig");
const BOOL = windows.BOOL;
const scanForwardedToastActivation = win32.scanForwardedToastActivation;

/// Blocking (PIPE_WAIT) mode with overlapped instances: the server thread
/// waits on an event for a client and for each request's bytes, so an idle
/// server never runs.
const ipc_server_pipe_mode = windows.PIPE_TYPE_BYTE |
    c.PIPE_READMODE_BYTE |
    c.PIPE_REJECT_REMOTE_CLIENTS;
const ipc_server_instance_access = c.PIPE_ACCESS_DUPLEX | windows.FILE_FLAG_OVERLAPPED;
/// The server claims the pipe NAME once, at startup, and never releases it
/// while it runs. `FILE_FLAG_FIRST_PIPE_INSTANCE` makes that claim fail if
/// any other process already owns the name, and every replacement instance
/// is created BEFORE the previous handle is closed, so the name is never
/// momentarily unowned for a squatter to take.
const ipc_server_pipe_access = ipc_server_instance_access | c.FILE_FLAG_FIRST_PIPE_INSTANCE;
const ipc_pipe_prefix = "\\\\.\\pipe\\noctty.";

const ForwardedArgIterator = struct {
    args: []const [:0]const u8,
    idx: usize = 0,

    pub fn next(self: *ForwardedArgIterator) ?[]const u8 {
        if (self.idx >= self.args.len) return null;
        defer self.idx += 1;
        return self.args[self.idx];
    }
};

fn defaultIpcNamespace() []const u8 {
    return if (builtin.mode == .Debug)
        "io.github.amanthanvi.noctty-debug"
    else
        "io.github.amanthanvi.noctty";
}

fn sanitizeIpcNamespace(alloc: Allocator, raw: ?[]const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw orelse defaultIpcNamespace(), &std.ascii.whitespace);
    const source = if (trimmed.len == 0) defaultIpcNamespace() else trimmed;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    for (source) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or char == '_') {
            try buf.append(alloc, char);
        } else {
            try buf.append(alloc, '_');
        }
    }

    if (buf.items.len == 0) try buf.appendSlice(alloc, defaultIpcNamespace());
    return try buf.toOwnedSlice(alloc);
}

fn allocIpcPipeName(
    alloc: Allocator,
    raw_namespace: ?[]const u8,
    elevated: bool,
) ![:0]const u16 {
    const namespace = try sanitizeIpcNamespace(alloc, raw_namespace);
    defer alloc.free(namespace);

    const pipe_name_utf8 = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
        ipc_pipe_prefix,
        namespace,
        if (elevated) ".elevated" else ".medium",
    });
    defer alloc.free(pipe_name_utf8);

    return try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_name_utf8);
}

pub fn resolveIpcPipeNameForTarget(
    alloc: Allocator,
    target: apprt.ipc.Target,
    elevated: bool,
) ![:0]const u16 {
    return switch (target) {
        .class => |class| allocIpcPipeName(alloc, class, elevated),
        .detect => allocIpcPipeName(alloc, null, elevated),
    };
}

/// Backing store for a copied SID. `SECURITY_MAX_SID_SIZE` is 68 bytes, so
/// 256 is ample. The alignment is required, not cosmetic: a `SID` ends in an
/// array of `DWORD` sub-authorities, and `EqualSid` reads them as such.
const SidBuffer = [256]u8;
const sid_buffer_align = @alignOf(u32);

/// Copy the current process token's user SID into `buf`, returning the
/// populated prefix.
fn currentUserSidBytes(buf: *align(sid_buffer_align) SidBuffer) ![]u8 {
    var token: windows.HANDLE = undefined;
    if (sys.OpenProcessToken(
        windows.kernel32.GetCurrentProcess(),
        c.TOKEN_QUERY,
        &token,
    ) == 0) return error.TokenQueryFailed;
    defer _ = windows.CloseHandle(token);
    return try tokenUserSidBytes(token, buf);
}

fn tokenUserSidBytes(
    token: windows.HANDLE,
    buf: *align(sid_buffer_align) SidBuffer,
) ![]u8 {
    var token_user_buf: [256]u8 align(@alignOf(sys.TOKEN_USER)) = undefined;
    var token_user_len: u32 = 0;
    if (sys.GetTokenInformation(
        token,
        c.TokenUser,
        &token_user_buf,
        token_user_buf.len,
        &token_user_len,
    ) == 0) return error.TokenQueryFailed;

    const token_user: *const sys.TOKEN_USER = @ptrCast(&token_user_buf);
    const sid_len = sys.GetLengthSid(token_user.User.Sid);
    if (sid_len == 0 or sid_len > buf.len) return error.TokenQueryFailed;

    const sid_bytes: [*]const u8 = @ptrCast(token_user.User.Sid);
    @memcpy(buf[0..sid_len], sid_bytes[0..sid_len]);
    return buf[0..sid_len];
}

/// The token's mandatory integrity label SID as a string, or null when the
/// token or the conversion fails. OS-allocated; free it with `sys.LocalFree`.
fn tokenIntegritySidString(token: windows.HANDLE) ?[*:0]u16 {
    var label_buf: [256]u8 align(@alignOf(sys.TOKEN_MANDATORY_LABEL)) = undefined;
    var label_len: u32 = 0;
    if (sys.GetTokenInformation(
        token,
        c.TokenIntegrityLevel,
        &label_buf,
        label_buf.len,
        &label_len,
    ) == 0) return null;
    const label: *const sys.TOKEN_MANDATORY_LABEL = @ptrCast(&label_buf);

    var sid_string: ?[*:0]u16 = null;
    if (sys.ConvertSidToStringSidW(label.Label.Sid, &sid_string) == 0) return null;
    return sid_string;
}

/// Mandatory integrity level of a token, as an `S-1-16-<rid>` RID: the
/// numeric value, which the comparison below needs.
fn tokenIntegrityRid(token: windows.HANDLE) ?u32 {
    const sid = tokenIntegritySidString(token) orelse return null;
    defer _ = sys.LocalFree(@ptrCast(sid));
    return integrityRidFromSidString(std.mem.span(sid));
}

/// Is this connected pipe object owned and labelled for our trust level?
///
/// The single-instance pipe name is derived only from `--class`, so it is
/// PREDICTABLE and lives in the machine-wide named-pipe namespace. Any local
/// account can therefore pre-create `\\.\pipe\noctty.<class>` before we do.
/// The server-side owner-only DACL does not help here: it protects the pipe
/// WE create, not the one we CONNECT to. Without this check a squatter would
/// receive our forwarded startup arguments (including the working directory)
/// and could return a forged ack, so the real instance never starts and the
/// user gets no window -- a cross-account disclosure plus a startup denial.
///
/// This runs before the first write. `ImpersonateNamedPipeClient` is
/// documented to impersonate "the security context of the last message read
/// from the pipe", so a server that has read nothing from us has no context
/// to assume. That ordering is a defence in depth rather than the guarantee,
/// though: the guarantee is that `connectToIpcPipe` opens with
/// `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`, which caps the server
/// at an identification-only token whatever the timing.
///
/// Authentication is read from the descriptor attached to THIS pipe object.
/// A PID lookup is not sufficient: a duplicated server handle can outlive
/// its creating process, and the numeric PID can then be recycled.
///
/// Fails CLOSED: any query or parse error answers "not ours".
fn ipcPipeServerIsTrusted(pipe: windows.HANDLE) bool {
    const information = c.OWNER_SECURITY_INFORMATION | c.LABEL_SECURITY_INFORMATION;
    var owner: ?*anyopaque = null;
    var descriptor: ?*anyopaque = null;
    if (sys.GetSecurityInfo(
        pipe,
        c.SE_KERNEL_OBJECT,
        information,
        &owner,
        null,
        null,
        null,
        &descriptor,
    ) != 0) return false;
    const attached = descriptor orelse return false;
    defer _ = sys.LocalFree(attached);

    var own_buf: SidBuffer align(sid_buffer_align) = undefined;
    const own_sid = currentUserSidBytes(&own_buf) catch return false;
    if (owner == null or sys.EqualSid(owner.?, @ptrCast(own_sid.ptr)) == 0) return false;

    // The user SID is NOT sufficient on its own. Under the ordinary split
    // UAC token, an elevated process and a medium-integrity process of the
    // same account carry the SAME user SID, so `EqualSid` alone would let a
    // medium-integrity squatter pre-create the predictable name and serve an
    // ELEVATED client -- which would then hand its forwarded arguments
    // downward and accept a forged ack. `SECURITY_IDENTIFICATION` prevents
    // the squatter impersonating us; it says nothing about who it is.
    //
    // So require the server to be at least our own integrity level. Equal is
    // fine (the normal case, and what the medium-to-medium path needs);
    // higher is fine (a medium client talking to an elevated instance is
    // already governed by the pipe's NO_WRITE_UP label); strictly lower is
    // refused.
    var own_token: windows.HANDLE = undefined;
    if (sys.OpenProcessToken(
        windows.kernel32.GetCurrentProcess(),
        c.TOKEN_QUERY,
        &own_token,
    ) == 0) return false;
    defer _ = windows.CloseHandle(own_token);

    const own_rid = tokenIntegrityRid(own_token) orelse return false;
    const server_rid = descriptorIntegrityRid(attached) catch return false;
    return server_rid >= own_rid;
}

fn descriptorIntegrityRid(descriptor: *anyopaque) error{InvalidSecurityDescriptor}!u32 {
    var text: ?[*:0]u16 = null;
    if (sys.ConvertSecurityDescriptorToStringSecurityDescriptorW(
        descriptor,
        c.SDDL_REVISION_1,
        c.LABEL_SECURITY_INFORMATION,
        &text,
        null,
    ) == 0) return error.InvalidSecurityDescriptor;
    const text_ptr = text orelse return error.InvalidSecurityDescriptor;
    defer _ = sys.LocalFree(@ptrCast(text_ptr));

    return descriptorIntegrityRidFromSddl(std.mem.span(text_ptr));
}

fn descriptorIntegrityRidFromSddl(sddl: []const u16) error{InvalidSecurityDescriptor}!u32 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("S-1-16-");
    if (std.mem.indexOf(u16, sddl, prefix)) |start| {
        var rid: u32 = 0;
        var digits: usize = 0;
        for (sddl[start + prefix.len ..]) |ch| {
            if (ch < '0' or ch > '9') break;
            rid = std.math.mul(u32, rid, 10) catch return error.InvalidSecurityDescriptor;
            rid = std.math.add(u32, rid, ch - '0') catch return error.InvalidSecurityDescriptor;
            digits += 1;
        }
        if (digits == 0) return error.InvalidSecurityDescriptor;
        return rid;
    }

    // Windows renders well-known mandatory-label SIDs using SDDL aliases.
    // The label-only descriptor contains no unrelated ACEs, so matching the
    // trustee suffix is unambiguous.
    const aliases = [_]struct { suffix: []const u16, rid: u32 }{
        .{ .suffix = std.unicode.utf8ToUtf16LeStringLiteral(";;;UN)"), .rid = 0x0000 },
        .{ .suffix = std.unicode.utf8ToUtf16LeStringLiteral(";;;LW)"), .rid = 0x1000 },
        .{ .suffix = std.unicode.utf8ToUtf16LeStringLiteral(";;;ME)"), .rid = 0x2000 },
        .{ .suffix = std.unicode.utf8ToUtf16LeStringLiteral(";;;MP)"), .rid = 0x2100 },
        .{ .suffix = std.unicode.utf8ToUtf16LeStringLiteral(";;;HI)"), .rid = 0x3000 },
        .{ .suffix = std.unicode.utf8ToUtf16LeStringLiteral(";;;SI)"), .rid = 0x4000 },
    };
    for (aliases) |alias| {
        if (std.mem.indexOf(u16, sddl, alias.suffix) != null) return alias.rid;
    }

    // The producer always emits an explicit label. Missing or unknown labels
    // must fail closed; otherwise a low-integrity same-user squatter can rely
    // on Windows' implicit-medium interpretation and impersonate our server.
    return error.InvalidSecurityDescriptor;
}

/// Connect to the single-instance IPC pipe as a client.
///
/// `error.FileNotFound` and `error.PipeUnreachable` both mean "there is no
/// instance we can talk to"; callers must treat them the same and fall back
/// to running locally. They are kept distinct only so the unreachable case
/// can be logged differently.
fn connectToIpcPipe(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
) !windows.HANDLE {
    var retries: u8 = 0;
    while (true) {
        const handle = windows.kernel32.CreateFileW(
            pipe_name.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            // Deny impersonation outright rather than relying on the server
            // never having read a message from us. See the constants.
            win32_ipc.client_pipe_open_flags,
            null,
        );
        if (handle != windows.INVALID_HANDLE_VALUE) {
            if (!ipcPipeServerIsTrusted(handle)) {
                _ = windows.CloseHandle(handle);
                log.warn(
                    "single-instance pipe owner or integrity label is not trusted; " ++
                        "refusing to forward anything to it",
                    .{},
                );
                return error.PipeUnreachable;
            }
            // The descriptor check above proves the server is the same user
            // and at least our integrity level. When we are elevated we also
            // read the server's TOKEN, which is a different source: it
            // survives a descriptor that was set once and then dropped, and
            // it is what `win32_elevation` tests against.
            if (elevated) {
                const trusted = win32_elevation.authenticateElevatedPipeServer(
                    alloc,
                    handle,
                ) catch |err| {
                    _ = windows.CloseHandle(handle);
                    log.warn("refusing elevated IPC server because authentication could not be completed err={}", .{err});
                    return error.UntrustedIpcServer;
                };
                if (!trusted) {
                    _ = windows.CloseHandle(handle);
                    log.warn("refusing elevated IPC server because its token owner or elevation state did not match", .{});
                    return error.UntrustedIpcServer;
                }
            }
            setIpcClientNonblocking(handle) catch |err| {
                _ = windows.CloseHandle(handle);
                return err;
            };
            return handle;
        }

        const err = windows.kernel32.GetLastError();
        switch (err) {
            .FILE_NOT_FOUND => return error.FileNotFound,

            // The pipe exists but this token may not open it. The common
            // cause is an elevated instance holding the name: its descriptor
            // carries a NO_WRITE_UP mandatory label, so a medium-integrity
            // client is denied at CreateFileW. That is the intended denial,
            // but it must NOT abort startup -- an ordinary non-elevated
            // launch has to fall through to its own local instance rather
            // than failing to open a window at all.
            .ACCESS_DENIED => return error.PipeUnreachable,

            .PIPE_BUSY => {
                if (retries == 0 and sys.WaitNamedPipeW(pipe_name.ptr, 1000) != 0) {
                    retries += 1;
                    continue;
                }
                return error.PipeBusy;
            },
            else => return windows.unexpectedError(err),
        }
    }
}

fn setIpcClientNonblocking(pipe: windows.HANDLE) !void {
    var mode: u32 = c.PIPE_READMODE_BYTE | win32_ipc.pipe_nowait;
    if (sys.SetNamedPipeHandleState(pipe, &mode, null, null) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
}

pub fn sendNewWindowIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    arguments: ?[]const [:0]const u8,
    response_timeout_ms: u64,
) !bool {
    const pipe = connectToIpcPipe(alloc, pipe_name, elevated) catch |err| switch (err) {
        error.FileNotFound, error.UntrustedIpcServer => return false,
        // No instance we are allowed to talk to. Report "not forwarded" so
        // the caller starts a local instance instead of aborting startup.
        error.PipeUnreachable => {
            log.info(
                "single-instance pipe exists but is not accessible to this token; starting a local instance",
                .{},
            );
            return false;
        },
        error.PipeBusy => return error.IPCFailed,
        else => return err,
    };
    defer _ = windows.CloseHandle(pipe);

    const request = try win32_ipc.encodeNewWindowRequest(alloc, arguments);
    defer alloc.free(request);

    try win32_ipc.writeAll(.{ .handle = pipe }, request);
    return try win32_ipc.readAckWithTimeout(pipe, response_timeout_ms);
}

pub fn sendListWindowsIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    response_timeout_ms: u64,
) !?[]u8 {
    const pipe = connectToIpcPipe(alloc, pipe_name, elevated) catch |err| switch (err) {
        // All three mean "no instance we can reach"; see `connectToIpcPipe`.
        error.FileNotFound, error.PipeUnreachable, error.UntrustedIpcServer => return null,
        error.PipeBusy => return error.IPCFailed,
        else => return err,
    };
    defer _ = windows.CloseHandle(pipe);

    const request = try win32_ipc.encodeListWindowsRequest(
        alloc,
        automationRequestDeadline(response_timeout_ms),
    );
    defer alloc.free(request);

    try win32_ipc.writeAll(.{ .handle = pipe }, request);
    return try win32_ipc.readDataResponseWithTimeout(
        alloc,
        pipe,
        std.math.maxInt(u64),
    );
}

pub fn sendPerformActionIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
    response_timeout_ms: u64,
) !bool {
    const request = try win32_ipc.encodePerformActionRequest(
        alloc,
        target,
        action_text,
        0,
    );
    defer alloc.free(request);
    return sendAutomationAckRequest(alloc, pipe_name, elevated, request, response_timeout_ms);
}

fn sendAutomationAckRequest(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    request: []u8,
    response_timeout_ms: u64,
) !bool {
    const pipe = connectToIpcPipe(alloc, pipe_name, elevated) catch |err| switch (err) {
        // All three mean "no instance we can reach"; see `connectToIpcPipe`.
        error.FileNotFound, error.PipeUnreachable, error.UntrustedIpcServer => return false,
        error.PipeBusy => return error.IPCFailed,
        else => return err,
    };
    defer _ = windows.CloseHandle(pipe);
    try win32_ipc.setAutomationRequestDeadline(
        request,
        automationRequestDeadline(response_timeout_ms),
    );
    try win32_ipc.writeAll(.{ .handle = pipe }, request);
    return win32_ipc.readAckWithTimeout(pipe, std.math.maxInt(u64));
}

pub fn sendFocusIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    target: apprt.ipc.AutomationTarget,
    response_timeout_ms: u64,
) !bool {
    const request = try win32_ipc.encodeFocusRequest(
        alloc,
        target,
        0,
    );
    defer alloc.free(request);
    return sendAutomationAckRequest(alloc, pipe_name, elevated, request, response_timeout_ms);
}

pub fn sendNewTabIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    target: apprt.ipc.AutomationTarget,
    working_directory: ?[]const u8,
    response_timeout_ms: u64,
) !bool {
    const request = try win32_ipc.encodeNewTabRequest(
        alloc,
        target,
        working_directory,
        0,
    );
    defer alloc.free(request);
    return sendAutomationAckRequest(alloc, pipe_name, elevated, request, response_timeout_ms);
}

pub fn sendNewSplitIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    target: apprt.ipc.AutomationTarget,
    direction: apprt.ipc.AutomationSplitDirection,
    working_directory: ?[]const u8,
    response_timeout_ms: u64,
) !bool {
    const request = try win32_ipc.encodeNewSplitRequest(
        alloc,
        target,
        direction,
        working_directory,
        0,
    );
    defer alloc.free(request);
    return sendAutomationAckRequest(alloc, pipe_name, elevated, request, response_timeout_ms);
}

pub fn sendAutomationTextIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    target: apprt.ipc.AutomationTarget,
    value: []const u8,
    response_timeout_ms: u64,
) !bool {
    const request = try win32_ipc.encodeSendTextRequest(
        alloc,
        target,
        value,
        0,
    );
    defer alloc.free(request);
    return sendAutomationAckRequest(alloc, pipe_name, elevated, request, response_timeout_ms);
}

fn automationRequestDeadline(response_timeout_ms: u64) u64 {
    return sys.GetTickCount64() +| response_timeout_ms;
}

pub fn automationTextAllowed(text: []const u8) bool {
    if (text.len == 0 or text.len > win32_ipc.max_action_text_len) return false;
    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0x1F or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F)) return false;
    }
    return win32_paste_protection.inspect(text).severity != .control_chars;
}

/// Configuration keys a forwarded `new_window` argv is allowed to set.
///
/// `applyNewWindowArguments` runs on the SERVER side of the single-instance
/// IPC pipe and feeds caller-controlled argv straight into `Config.loadIter`,
/// so the automation allowlist in `App.isSafeAutomationAction` is not the
/// boundary for this request kind. Any process running as this user can write
/// to the pipe, so this argv must be treated as untrusted input.
///
/// This is an ALLOWLIST, deliberately, and not a denylist. The config surface
/// is ~190 fields and grows with every upstream merge; a denylist gets it
/// wrong by omission every time a new key lands. Deny-by-default means an
/// unrecognised key -- including any key added upstream after this list was
/// written -- is refused until someone reviews it.
///
/// Admission rule: a key qualifies only if its value is a scalar, an enum, a
/// color, or (for `title`) a display string that is sanitized downstream. A
/// key does NOT qualify if its value is resolved as a filesystem path, a
/// command, an environment variable, a font or theme NAME looked up against
/// something, an additional configuration source, or bytes that can reach the
/// pty. That rule excludes, among others:
///
///   - `command`, `initial-command`, `-e`  -> become the spawned child.
///   - `input`                             -> written straight to the pty;
///     its own doc comment warns it can execute programs in a shell.
///   - `env`                               -> overrides are applied AFTER
///     `shell_integration.setup`, so `ZDOTDIR` / `ENV` / `XDG_DATA_DIRS` /
///     `GHOSTTY_BASH_RCFILE` / `PATH` become code execution at shell start.
///   - `config-file`, `config-default-files`, `theme` -> config sources.
///     `theme` accepts an absolute path and is parsed as a full config file
///     (`config/theme.zig` `open`), so it is a `config-file` by proxy.
///   - `background-image`, `bell-audio-path`, `custom-shader`,
///     `gtk-custom-css`                    -> arbitrary file reads, and UNC
///     values make this process authenticate to a remote SMB host.
///   - `keybind`, `command-palette-entry`  -> inject attacker-chosen binding
///     actions, re-opening the `.perform_action` allowlist by another door.
///   - `enquiry-response`                  -> attacker bytes written to the
///     pty when the child sends ENQ.
///   - `title-report`, `window-save-state`, `class` -> not presentation.
///   - `font-family*`, `font-style*`, `font-feature`, `font-variation*`,
///     `font-codepoint-map`, `window-title-font-family` -> name strings that
///     are resolved by font discovery. Excluded on the admission rule rather
///     than because a concrete exploit is known.
///
/// `working-directory` is handled separately: it is admitted, but its VALUE
/// is constrained by `forwardedWorkingDirectoryAllowed`.
const forwarded_argv_allowed_keys = [_][]const u8{
    // Window geometry, decoration, and state.
    "window-width",
    "window-height",
    "window-position-x",
    "window-position-y",
    "window-padding-x",
    "window-padding-y",
    "window-padding-balance",
    "window-padding-color",
    "window-decoration",
    "window-theme",
    "accent-follow-system",
    "window-colorspace",
    "window-subtitle",
    "window-titlebar-background",
    "window-titlebar-foreground",
    "window-show-tab-bar",
    "window-new-tab-position",
    "window-step-resize",
    "window-vsync",
    "maximize",
    "fullscreen",
    "title",

    // Font sizing and rendering. Font NAME keys are deliberately absent.
    "font-size",
    "font-thicken",
    "font-thicken-strength",
    "font-synthetic-style",
    "font-shaping-break",

    // Colors and compositing.
    "background",
    "foreground",
    "palette",
    "selection-foreground",
    "selection-background",
    "cursor-color",
    "cursor-text",
    "cursor-style",
    "cursor-style-blink",
    "cursor-opacity",
    "background-opacity",
    "background-opacity-cells",
    "background-blur",
    "unfocused-split-opacity",
    "unfocused-split-fill",
    "split-divider-color",
    "bold-color",
    "faint-opacity",
    "minimum-contrast",
    "alpha-blending",
};

/// The one allowlisted key whose value needs its own check.
const forwarded_working_directory_key = "working-directory";

/// Extract the config key from a forwarded argument, or null when the
/// argument is not in `--key[=value]` form.
///
/// `cli/args.zig` (:112-133) takes `key = arg[2..]` up to the first `=` and
/// matches it with exact case-sensitive `mem.eql` against field names. There
/// is no prefix abbreviation, no `--key value` separate-token form, no case
/// folding, and no underscore/hyphen aliasing, so this sees exactly the key
/// the loader will act on.
fn forwardedArgumentKey(arg: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const body = arg[2..];
    return if (std.mem.indexOfScalar(u8, body, '=')) |idx| body[0..idx] else body;
}

/// True when a forwarded argv sets config `key`, whatever its value.
pub fn forwardedArgvSetsKey(argv: []const [:0]const u8, key: []const u8) bool {
    for (argv) |arg| {
        const set = forwardedArgumentKey(arg) orelse continue;
        if (std.mem.eql(u8, set, key)) return true;
    }
    return false;
}

/// True when a forwarded config key is on the allowlist. `working-directory`
/// is included here; its value is checked separately.
pub fn forwardedKeyAllowed(key: []const u8) bool {
    if (std.mem.eql(u8, key, forwarded_working_directory_key)) return true;
    for (forwarded_argv_allowed_keys) |allowed| {
        if (std.mem.eql(u8, key, allowed)) return true;
    }
    return false;
}

/// True when a key is safe to echo into a log line.
///
/// The refused key comes from the pipe, so it is attacker-controlled text and
/// must not be logged raw (newlines would forge log records). Real config keys
/// are lowercase ASCII with hyphens and digits, so anything else is reported
/// generically instead.
fn forwardedKeyLoggable(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    for (key) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '-';
        if (!ok) return false;
    }
    return true;
}

/// Returns true when a forwarded `--working-directory` value is one the
/// server is willing to honor.
///
/// The startup forwarder always sends the launching process's realpath'd cwd
/// (`collectStartupForwardArguments`), so this key cannot be rejected
/// outright without breaking every single-instance launch. It is instead
/// constrained to the symbolic values, a home-relative path, or a local
/// drive-letter absolute path.
///
/// SCOPE OF THIS CHECK, stated precisely: it rejects UNC *syntax* only. A
/// mapped drive (`net use Z: \\host\share`), a `subst` drive, or a junction
/// under a local drive still resolves off-box, and any same-user process can
/// create those. That is acceptable under this channel's threat model --
/// same-user code is already trusted -- and the point of the check is to stop
/// a bare `\\attacker\share` value from making the server authenticate to an
/// attacker-chosen SMB host.
///
/// The check is deliberately PURELY SYNTACTIC. An earlier version called
/// `openDirAbsolute` to confirm the directory existed, but that resolution is
/// itself the SMB authentication we are trying to avoid for mapped drives and
/// junctions, and it was defeated by TOCTOU anyway since the path is
/// re-resolved at spawn time.
fn forwardedWorkingDirectoryAllowed(value: []const u8) bool {
    var trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);

    // `Config.parseCLI` strips one pair of surrounding double quotes, so a
    // quoted path is a legal value and must not be refused here.
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        trimmed = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &std.ascii.whitespace);
    }

    if (std.mem.eql(u8, trimmed, "home")) return true;
    if (std.mem.eql(u8, trimmed, "inherit")) return true;

    // `~`, `~/...` and `~\...` are documented legal values that
    // `WorkingDirectory.finalize` expands against the user's own home
    // directory, so they cannot point off-box.
    if (std.mem.eql(u8, trimmed, "~")) return true;
    if (trimmed.len >= 2 and trimmed[0] == '~' and
        (trimmed[1] == '/' or trimmed[1] == '\\')) return true;

    // Everything else must be a local drive-letter absolute path. This
    // rejects UNC (`\\host\share`, `//host/share`), device namespace
    // (`\\?\`, `\\.\`), relative (`foo\bar`) and drive-relative (`C:foo`).
    if (trimmed.len < 3) return false;
    if (!std.ascii.isAlphabetic(trimmed[0])) return false;
    if (trimmed[1] != ':') return false;
    if (trimmed[2] != '\\' and trimmed[2] != '/') return false;
    return true;
}

/// Why a forwarded argv was refused. `key` borrows from the argument and is
/// only safe to log when `forwardedKeyLoggable(key)`.
const ForwardedArgvRejection = struct {
    reason: enum { not_allowlisted, bad_working_directory, not_a_config_flag },
    key: []const u8,
};

/// Scan a forwarded `new_window` argv and describe the first argument that
/// must not be honored, or null when every argument is acceptable.
///
/// Every element is scanned, so a repeated or trailing occurrence of a key
/// cannot slip past by appearing after an acceptable one.
pub fn forwardedArgvRejection(argv: []const [:0]const u8) ?ForwardedArgvRejection {
    for (argv) |arg| {
        const key = forwardedArgumentKey(arg) orelse {
            // Not `--key[=value]`. `-e` lands here, and
            // `Config.parseManuallyHook` would turn it into
            // `initial-command`. Nothing in this form is ever legitimate on
            // a forwarded argv, so refuse rather than relying on the loader
            // to treat it as an inert diagnostic.
            return .{ .reason = .not_a_config_flag, .key = arg };
        };

        if (!forwardedKeyAllowed(key)) {
            return .{ .reason = .not_allowlisted, .key = key };
        }

        if (std.mem.eql(u8, key, forwarded_working_directory_key)) {
            const value = if (std.mem.indexOfScalar(u8, arg, '=')) |idx|
                arg[idx + 1 ..]
            else
                "";
            if (!forwardedWorkingDirectoryAllowed(value)) {
                return .{ .reason = .bad_working_directory, .key = key };
            }
        }
    }
    return null;
}

/// Log a refused forwarded argv at error level, without echoing untrusted
/// text into the log.
pub fn logForwardedArgvRejection(rejection: ForwardedArgvRejection) void {
    switch (rejection.reason) {
        .bad_working_directory => log.err(
            "refusing forwarded new-window argv: working-directory must be home, inherit, ~/..., or a local absolute path",
            .{},
        ),
        .not_a_config_flag => log.err(
            "refusing forwarded new-window argv: contains an argument that is not a --key=value config flag",
            .{},
        ),
        .not_allowlisted => if (forwardedKeyLoggable(rejection.key)) log.err(
            "refusing forwarded new-window argv: key {s} is not permitted over IPC",
            .{rejection.key},
        ) else log.err(
            "refusing forwarded new-window argv: contains a key that is not permitted over IPC",
            .{},
        ),
    }
}

pub fn sendLaunchLayoutIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    name: []const u8,
    response_timeout_ms: u64,
) !bool {
    // Validate before probing the pipe. The caller uses `false` as the cold
    // start fallback, so connecting first would let an invalid name spawn an
    // otherwise ordinary window when no instance is listening.
    const request = try win32_ipc.encodeLaunchLayoutRequest(
        alloc,
        name,
        0,
    );
    defer alloc.free(request);
    return sendAutomationAckRequest(alloc, pipe_name, elevated, request, response_timeout_ms);
}

fn trySendStartupLaunchLayoutIpc(
    alloc: Allocator,
    pipe_name: [:0]const u16,
    elevated: bool,
    request: App.StartupLaunchLayout,
) !?bool {
    // A request this one cannot carry (its name lost, or one the layout
    // request refuses) is not forwarded, and not handed to the generic argv
    // forward either, which opens a plain window: this process opens it, and
    // `run` reports the failure in its first window. An error here would end
    // the launch in a failure dialog, its startup attempt unresolved.
    const layout_name = switch (request) {
        .none => return null,
        .lost => return false,
        .name => |name| name,
    };
    win32_ipc.validateLaunchLayoutName(layout_name) catch return false;
    return try sendLaunchLayoutIpc(
        alloc,
        pipe_name,
        elevated,
        layout_name,
        win32_ipc.automation_response_timeout_ms,
    );
}

const LaunchLayoutIpcArgument = union(enum) {
    none,
    name: []const u8,
};

pub fn scanLaunchLayoutIpcArgument(
    arguments: ?[]const [:0]const u8,
) !LaunchLayoutIpcArgument {
    const argv = arguments orelse return .none;
    const prefix = "--launch-layout=";
    var name: ?[]const u8 = null;
    for (argv) |arg| {
        // Config parsing treats everything after -e as command payload.
        // Match that boundary so a child command may legitimately receive an
        // argument that looks like a Noctty layout option.
        if (std.mem.eql(u8, arg, "-e")) break;
        if (!std.mem.startsWith(u8, arg, prefix)) continue;
        if (name != null) return error.MixedLaunchLayoutArguments;
        name = arg[prefix.len..];
    }

    if (name) |value| {
        if (argv.len != 1) return error.MixedLaunchLayoutArguments;
        return .{ .name = value };
    }
    return .none;
}

fn automationWorkingDirectoryValue(value: []const u8) []const u8 {
    var result = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (result.len >= 2 and result[0] == '"' and result[result.len - 1] == '"') {
        result = std.mem.trim(u8, result[1 .. result.len - 1], &std.ascii.whitespace);
    }
    return result;
}

/// Mirrors #185's `forwardedWorkingDirectoryAllowed` on the receiver.
pub fn automationWorkingDirectoryAllowed(value: []const u8) bool {
    const path = automationWorkingDirectoryValue(value);
    if (std.mem.eql(u8, path, "home") or std.mem.eql(u8, path, "inherit") or
        std.mem.eql(u8, path, "~")) return true;
    if (path.len >= 2 and path[0] == '~' and (path[1] == '/' or path[1] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path[2] == '/' or path[2] == '\\');
}

pub fn applyAutomationWorkingDirectory(config: *configpkg.Config, value: []const u8) !void {
    if (!automationWorkingDirectoryAllowed(value)) return error.AutomationPolicyRefused;
    const alloc = config._arena.?.allocator();
    const path = automationWorkingDirectoryValue(value);
    if (std.mem.eql(u8, path, "~")) {
        config.@"working-directory" = .home;
        return;
    }
    var working_directory: configpkg.WorkingDirectory = undefined;
    if (path.len >= 2 and path[0] == '~' and path[1] == '\\') {
        const normalized = try alloc.dupe(u8, path);
        normalized[1] = '/';
        working_directory = .{ .path = normalized };
    } else {
        working_directory = .home;
        try working_directory.parseCLI(alloc, path);
    }
    try working_directory.finalize(alloc);
    config.@"working-directory" = working_directory;
}

/// Apply a forwarded `new_window` argv to `config`.
///
/// Returns `error.ForbiddenForwardedArgument` for the whole request if any
/// argument is rejected. Dropping individual keys silently would leave the
/// caller with a window that does not match what was asked for, and would
/// make an attacker's probe indistinguishable from a normal launch.
///
/// This function does not log, so that it stays a pure predicate over argv
/// and can be unit tested; every caller logs the rejection it handles.
pub fn applyNewWindowArguments(
    alloc_gpa: Allocator,
    config: *configpkg.Config,
    arguments: ?[]const [:0]const u8,
) !void {
    const argv = arguments orelse return;
    if (argv.len == 0) return;

    if (forwardedArgvRejection(argv) != null) {
        return error.ForbiddenForwardedArgument;
    }

    // This clone inherits the app config's replay history, and `+new-window`
    // always forwards at least a working directory, so the `finalize` below
    // always runs. `launch-layout` is one-shot: an inherited startup step
    // replayed here would turn an ordinary new window into a layout launch.
    _ = config.dropLaunchLayoutReplaySteps(0);
    config.@"launch-layout" = null;

    var iter: ForwardedArgIterator = .{ .args = argv };
    try config.loadIter(alloc_gpa, &iter);
    try config.finalize();
}

fn normalizeForwardedStartupArg(
    alloc: Allocator,
    arg: []const u8,
) !?[:0]const u8 {
    if (std.mem.startsWith(u8, arg, "--class=") or
        std.mem.startsWith(u8, arg, "--single-instance=") or
        std.mem.startsWith(u8, arg, "--gtk-single-instance=") or
        std.mem.eql(u8, arg, "--safe-mode"))
    {
        return null;
    }

    // Action Center launches carry the target as a positional URI. Preserve
    // only a URI that the same parser used by the receiver accepts; malformed
    // lookalikes still fall through to the non-flag rejection below.
    if (win32_toast_activation.parseLaunchArg(arg)) |_| {
        return try alloc.dupeZ(u8, arg);
    } else |_| {}

    // Drop anything the running instance would refuse, so an ordinary launch
    // still gets a window instead of having the whole request rejected. This
    // is a usability measure on OUR OWN argv, not a security control -- the
    // server re-checks every argument, because a hostile pipe writer never
    // runs this code.
    const key = forwardedArgumentKey(arg) orelse {
        log.warn("not forwarding non-flag startup argument to the running instance", .{});
        return null;
    };
    if (!forwardedKeyAllowed(key)) {
        log.warn(
            "not forwarding {s} to the running instance: it may not be set over IPC",
            .{key},
        );
        return null;
    }

    if (std.mem.startsWith(u8, arg, "--working-directory=")) {
        const raw = arg["--working-directory=".len..];
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (std.mem.eql(u8, trimmed, "home") or std.mem.eql(u8, trimmed, "inherit")) {
            return try alloc.dupeZ(u8, arg);
        }

        const cwd = std.fs.cwd();
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const expanded = homedir.expandHome(trimmed, &home_buf) catch trimmed;
        var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
        const normalized = cwd.realpath(expanded, &realpath_buf) catch expanded;

        // The key check above is not enough for this one option: the server
        // refuses the ENTIRE argv on a bad working-directory VALUE, and it
        // has already acknowledged the request by then, so the launching
        // process exits having produced no window at all. Dropping just this
        // argument here is what makes the "still gets a window" promise
        // above true for `--working-directory=\\host\share` and friends.
        return try allocForwardedWorkingDirectoryArg(alloc, normalized);
    }

    return try alloc.dupeZ(u8, arg);
}

fn allocForwardedWorkingDirectoryArg(
    alloc: Allocator,
    value: []const u8,
) !?[:0]const u8 {
    if (!forwardedWorkingDirectoryAllowed(value)) {
        log.warn(
            "not forwarding --working-directory to the running instance: " ++
                "value is not a local absolute path",
            .{},
        );
        return null;
    }

    return try std.fmt.allocPrintSentinel(
        alloc,
        "--working-directory={s}",
        .{value},
        0,
    );
}

fn collectStartupForwardArguments(alloc: Allocator) !?[]const [:0]const u8 {
    var iter = try cli_args.argsIterator(alloc);
    defer iter.deinit();

    var argv: std.ArrayList([:0]const u8) = .empty;
    var working_directory_seen = false;
    errdefer {
        for (argv.items) |arg| alloc.free(arg);
        argv.deinit(alloc);
    }

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--working-directory=")) {
            working_directory_seen = true;
        }
        if (try normalizeForwardedStartupArg(alloc, arg)) |normalized| {
            try argv.append(alloc, normalized);
        }
    }

    if (!working_directory_seen) {
        const cwd = std.fs.cwd();
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const wd = try cwd.realpath(".", &cwd_buf);
        if (try allocForwardedWorkingDirectoryArg(alloc, wd)) |arg| {
            try argv.insert(alloc, 0, arg);
        }
    }

    if (argv.items.len == 0) {
        argv.deinit(alloc);
        return null;
    }

    return try argv.toOwnedSlice(alloc);
}

/// Parse the relative identifier out of an integrity-level SID string of the
/// form `S-1-16-<rid>`. Returns null for anything that is not a mandatory
/// label SID, so callers fail closed rather than mislabelling the pipe.
fn integrityRidFromSidString(sid: []const u16) ?u32 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("S-1-16-");
    if (sid.len <= prefix.len) return null;
    if (!std.mem.eql(u16, sid[0..prefix.len], prefix)) return null;

    var rid: u32 = 0;
    for (sid[prefix.len..]) |unit| {
        if (unit < '0' or unit > '9') return null;
        rid = std.math.mul(u32, rid, 10) catch return null;
        rid = std.math.add(u32, rid, @intCast(unit - '0')) catch return null;
    }
    return rid;
}

/// Render the SDDL text for the IPC pipe security descriptor into `buf`.
///
/// `D:P` is a protected DACL (no inherited ACEs) holding exactly one ACE:
/// `GENERIC_ALL` for `user_sid`. An explicit mandatory-label ACE with the
/// `NO_WRITE_UP` policy is always appended, which both prevents write-up and
/// lets clients reject unlabeled same-user squatters.
///
/// RESIDUAL: `NO_WRITE_UP` does not deny reads, so a medium-integrity
/// process can open an elevated instance's pipe for `GENERIC_READ` (a bare
/// `READ_CONTROL` suffices). `WriteFile` on that handle then fails with
/// `win32=5`, so this is an OCCUPANCY problem, not an access break —
/// nothing is disclosed and no request can be submitted. But the server
/// offers one pipe instance at a time, so one such open makes the next
/// legitimate client fail with `win32=231 ERROR_PIPE_BUSY`. All of this is
/// observed on hardware, not inferred.
///
/// The fix is `NO_READ_UP`, and it lands with the elevation work rather
/// than here: that change labels the elevated endpoint `NWNR`, and the
/// added `NR` has been verified on hardware to deny every medium open
/// including `GENERIC_READ` and `READ_CONTROL`. Duplicating it here would
/// collide on the same SDDL term for no net gain, and would invalidate the
/// live descriptor readback recorded in docs/windows.md.
fn buildIpcPipeSddl(
    buf: []u16,
    user_sid: []const u16,
    integrity_sid: []const u16,
) error{IpcSecurityDescriptorFailed}![:0]u16 {
    var len: usize = 0;

    const Appender = struct {
        fn append(dest: []u16, at: *usize, text: []const u16) error{IpcSecurityDescriptorFailed}!void {
            // Reserve one unit for the sentinel.
            if (text.len + 1 > dest.len - at.*) return error.IpcSecurityDescriptorFailed;
            @memcpy(dest[at.*..][0..text.len], text);
            at.* += text.len;
        }
    };

    try Appender.append(buf, &len, std.unicode.utf8ToUtf16LeStringLiteral("O:"));
    try Appender.append(buf, &len, user_sid);
    try Appender.append(buf, &len, std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;"));
    try Appender.append(buf, &len, user_sid);
    try Appender.append(buf, &len, std.unicode.utf8ToUtf16LeStringLiteral(")"));

    try Appender.append(buf, &len, std.unicode.utf8ToUtf16LeStringLiteral("S:(ML;;NW;;;"));
    try Appender.append(buf, &len, integrity_sid);
    try Appender.append(buf, &len, std.unicode.utf8ToUtf16LeStringLiteral(")"));

    buf[len] = 0;
    return buf[0..len :0];
}

/// Resolve the process token's mandatory integrity level as an SDDL SID
/// string at every integrity level.
///
/// Windows does not auto-label kernel objects created by a high-integrity
/// process, and an unlabeled object evaluates as medium. Because the token
/// USER SID is identical across the elevated and non-elevated tokens of one
/// account, a DACL keyed on that SID alone would let a filtered medium-IL
/// process drive an elevated instance's pipe. Returning the label SID here
/// lets the caller add `S:(ML;;NW;;;S-1-16-<rid>)`, which blocks write-up.
///
/// RESIDUAL: the policy is `NW` only, not `NR`/`NX`. See the fuller note on
/// `buildIpcPipeSddl`; in short, and now measured rather than assumed, a
/// medium-integrity process can open an elevated instance's pipe for
/// `GENERIC_READ` -- a bare `READ_CONTROL` is enough, it need not request
/// read data access at all -- and `WriteFile` on that handle then fails
/// `win32=5`. So this is an OCCUPANCY problem, not an access break, but the
/// server offers one pipe instance at a time, so one such handle makes the
/// next legitimate client fail `win32=231 ERROR_PIPE_BUSY`.
///
/// `NR` closes it, and that is no longer a supposition: the elevation work
/// labels its elevated endpoint `NWNR`, and hardware verification shows the
/// `NR` denies every medium open including `GENERIC_READ` and
/// `READ_CONTROL`. It is supplied there rather than duplicated here, since
/// both would collide on the same SDDL term for no net gain once they land,
/// and changing the label here would invalidate this PR's live descriptor
/// readback.
///
/// The returned string is OS-allocated; free it with `sys.LocalFree`.
fn allocIpcPipeIntegritySid(token: windows.HANDLE) ![*:0]u16 {
    const sid = tokenIntegritySidString(token) orelse return error.IpcSecurityDescriptorFailed;
    _ = integrityRidFromSidString(std.mem.span(sid)) orelse {
        _ = sys.LocalFree(@ptrCast(sid));
        return error.IpcSecurityDescriptorFailed;
    };
    return sid;
}

/// Build the security descriptor for the single-instance IPC pipe: a
/// protected DACL whose only ACE grants full access to the SID that owns
/// this process, plus an explicit mandatory-label ACE at the process's exact
/// integrity level. Without it the pipe gets the default DACL, which is wider
/// than the same-user contract the IPC verbs assume.
///
/// The current user's SID is resolved from the process token rather than
/// using the `OW` (owner rights) SDDL alias, because an elevated token's
/// default object owner is the Administrators group, not the user.
///
/// Returns a descriptor allocated by the OS; free it with `sys.LocalFree`.
fn allocIpcPipeSecurityDescriptor() !*anyopaque {
    var token: windows.HANDLE = undefined;
    if (sys.OpenProcessToken(
        windows.kernel32.GetCurrentProcess(),
        c.TOKEN_QUERY,
        &token,
    ) == 0) return error.IpcSecurityDescriptorFailed;
    defer _ = windows.CloseHandle(token);

    // A TOKEN_USER plus the largest well-formed SID fits comfortably here;
    // SECURITY_MAX_SID_SIZE is 68 bytes.
    var token_user_buf: [256]u8 align(@alignOf(sys.TOKEN_USER)) = undefined;
    var token_user_len: u32 = 0;
    if (sys.GetTokenInformation(
        token,
        c.TokenUser,
        &token_user_buf,
        token_user_buf.len,
        &token_user_len,
    ) == 0) return error.IpcSecurityDescriptorFailed;
    const token_user: *const sys.TOKEN_USER = @ptrCast(&token_user_buf);

    var sid_string: ?[*:0]u16 = null;
    if (sys.ConvertSidToStringSidW(
        token_user.User.Sid,
        &sid_string,
    ) == 0) return error.IpcSecurityDescriptorFailed;
    const sid = sid_string orelse return error.IpcSecurityDescriptorFailed;
    defer _ = sys.LocalFree(@ptrCast(sid));

    const integrity_sid = try allocIpcPipeIntegritySid(token);
    defer _ = sys.LocalFree(@ptrCast(integrity_sid));

    // Pin the owner to the token user as well as granting that SID access.
    // The client authenticates the owner and mandatory label directly from
    // the connected pipe object, avoiding a recyclable process-ID lookup.
    var sddl_buf: [320]u16 = undefined;
    const sddl = try buildIpcPipeSddl(
        &sddl_buf,
        std.mem.span(sid),
        std.mem.span(integrity_sid),
    );

    var descriptor: ?*anyopaque = null;
    if (sys.ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl.ptr,
        c.SDDL_REVISION_1,
        &descriptor,
        null,
    ) == 0) return error.IpcSecurityDescriptorFailed;

    return descriptor orelse error.IpcSecurityDescriptorFailed;
}

fn createIpcServerPipe(
    pipe_name: [:0]const u16,
    attributes: *windows.SECURITY_ATTRIBUTES,
    first_instance: bool,
) windows.HANDLE {
    return sys.CreateNamedPipeW(
        pipe_name.ptr,
        if (first_instance) ipc_server_pipe_access else ipc_server_instance_access,
        ipc_server_pipe_mode,
        c.PIPE_UNLIMITED_INSTANCES,
        16 * 1024,
        16 * 1024,
        0,
        attributes,
    );
}

/// Serve the single-instance IPC pipe.
///
/// The first instance is claimed by `startIpcServer` rather than here,
/// because the claim RESULT is a startup decision: losing it means another
/// instance already owns this integrity-scoped name, and the loser retries
/// its startup forward instead of listening. `security_arg` owns the
/// descriptor every instance is created with and is released here, and so is
/// `io_event`, the manual-reset event every connect, read and write on an
/// instance completes on. `stopIpcServer` sets `stop_event`, which ends any
/// wait, so it never has to connect to the server to wake it.
fn ipcServerMain(
    app: *App,
    first_pipe: windows.HANDLE,
    security_arg: win32_elevation.IpcPipeSecurity,
    io_event: windows.HANDLE,
    stop_event: windows.HANDLE,
) void {
    var security = security_arg;
    defer security.deinit();
    defer _ = windows.CloseHandle(io_event);
    const security_attributes = security.securityAttributes();

    var pipe = first_pipe;
    defer _ = windows.CloseHandle(pipe);

    const pipe_name = app.ipc_pipe_name orelse return;

    while (true) {
        if (connectIpcClient(pipe, io_event, stop_event)) |connected| {
            if (!connected) return;
            handleIpcClient(app, .{
                .handle = pipe,
                .event = io_event,
                .stop_event = stop_event,
            }) catch |err| if (err != error.IpcStopped) {
                log.warn("failed to process win32 IPC client err={}", .{err});
            };
        } else |err| {
            // Includes a client that connected and left before this instance
            // was picked up; the instance cannot serve anyone else, so it is
            // replaced like one that served a request.
            log.warn("failed to connect win32 IPC client err={}", .{err});
        }
        if (app.ipc_stop_requested.load(.acquire)) return;

        const replacement = createIpcServerPipe(
            pipe_name,
            security_attributes,
            false,
        );
        if (replacement == windows.INVALID_HANDLE_VALUE) {
            log.warn("failed to preserve win32 IPC pipe ownership err={}", .{
                windows.kernel32.GetLastError(),
            });
            return;
        }
        // Each pipe instance serves one request. Closing only the server handle
        // keeps unread response bytes available through the client's handle;
        // DisconnectNamedPipe would discard them. The replacement is created
        // first so the name is never released while the server is running.
        _ = windows.CloseHandle(pipe);
        pipe = replacement;
    }
}

/// Wait for a client to connect to `pipe`. Returns false when the server is
/// asked to stop first.
fn connectIpcClient(
    pipe: windows.HANDLE,
    io_event: windows.HANDLE,
    stop_event: windows.HANDLE,
) !bool {
    var overlapped = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.hEvent = io_event;
    if (sys.ConnectNamedPipe(pipe, &overlapped) == 0) switch (windows.kernel32.GetLastError()) {
        .IO_PENDING => {},
        // A client opened the instance before this accept was issued.
        .PIPE_CONNECTED => return true,
        // ...and has already closed it again.
        .NO_DATA => return error.EndOfStream,
        else => |err| return windows.unexpectedError(err),
    };
    _ = win32_ipc.awaitOverlapped(pipe, &overlapped, stop_event, std.math.maxInt(u64)) catch |err| switch (err) {
        error.IpcStopped => return false,
        else => return err,
    };
    return true;
}

fn createIpcServerEvent() ?windows.HANDLE {
    return windows.CreateEventExW(
        null,
        null,
        windows.CREATE_EVENT_MANUAL_RESET,
        windows.EVENT_ALL_ACCESS,
    ) catch |err| {
        log.warn("failed to create win32 IPC server event; continuing without an IPC server err={}", .{err});
        return null;
    };
}

fn handleIpcClient(app: *App, pipe: win32_ipc.Pipe) !void {
    const kind = win32_ipc.decodeRequestKind(pipe) catch |err| {
        win32_ipc.writeAck(pipe, false) catch {};
        return err;
    };

    switch (kind) {
        .new_window => handleNewWindowIpcClient(app, pipe) catch |err| {
            log.warn("failed to process win32 new-window IPC request err={}", .{err});
            try win32_ipc.writeAck(pipe, false);
        },
        .list_windows, .list_windows_timed => handleListWindowsIpcClient(
            app,
            pipe,
            kind == .list_windows_timed,
        ) catch |err| {
            log.warn("failed to process win32 automation list IPC request err={}", .{err});
            try win32_ipc.writeDataResponse(pipe, false, "");
        },
        .perform_action, .perform_action_timed => handlePerformActionIpcClient(
            app,
            pipe,
            kind == .perform_action_timed,
        ) catch |err| {
            log.warn("failed to process win32 automation action IPC request err={}", .{err});
            try win32_ipc.writeAck(pipe, false);
        },
        .launch_layout, .launch_layout_timed => handleLaunchLayoutIpcClient(
            app,
            pipe,
            kind == .launch_layout_timed,
        ) catch |err| {
            log.warn("failed to process win32 launch-layout IPC request err={}", .{err});
            try win32_ipc.writeAck(pipe, false);
        },
        .new_tab, .new_tab_timed => handleNewTabIpcClient(
            app,
            pipe,
            kind == .new_tab_timed,
        ) catch |err| {
            log.warn("failed to process win32 automation new-tab IPC request err={}", .{err});
            try win32_ipc.writeAck(pipe, false);
        },
        .new_split, .new_split_timed => handleNewSplitIpcClient(
            app,
            pipe,
            kind == .new_split_timed,
        ) catch |err| {
            log.warn("failed to process win32 automation new-split IPC request err={}", .{err});
            try win32_ipc.writeAck(pipe, false);
        },
        .focus, .focus_timed => handleFocusIpcClient(
            app,
            pipe,
            kind == .focus_timed,
        ) catch |err| {
            log.warn("failed to process win32 automation focus IPC request err={}", .{err});
            try win32_ipc.writeAck(pipe, false);
        },
        .send_text, .send_text_timed => handleSendTextIpcClient(
            app,
            pipe,
            kind == .send_text_timed,
        ) catch |err| {
            log.warn("failed to process win32 automation send-text IPC request err={}", .{err});
            try win32_ipc.writeAck(pipe, false);
        },
    }
}

fn handleNewWindowIpcClient(app: *App, pipe: win32_ipc.Pipe) !void {
    const arguments = try win32_ipc.decodeNewWindowPayload(app.core_app.alloc, pipe);
    errdefer win32_ipc.freeOwnedArguments(app.core_app.alloc, arguments);

    // Reject policy-invalid requests before the success ACK. The UI-thread
    // path repeats the same checks as defense in depth, but acknowledging
    // here first would make +new-window exit successfully without creating a
    // window.
    if (!newWindowIpcArgumentsAccepted(arguments)) {
        try win32_ipc.writeAck(pipe, false);
        win32_ipc.freeOwnedArguments(app.core_app.alloc, arguments);
        return;
    }

    if (!pushIpcMailboxMessage(app, .{ .new_window = .{ .arguments = arguments } })) {
        return error.IPCFailed;
    }

    try win32_ipc.writeAck(pipe, true);
}

fn newWindowIpcArgumentsAccepted(arguments: ?[]const [:0]const u8) bool {
    const argv = arguments orelse return true;
    return switch (scanForwardedToastActivation(argv)) {
        .activation => true,
        .malformed => false,
        .none => forwardedArgvRejection(argv) == null,
    };
}

fn handleListWindowsIpcClient(app: *App, pipe: win32_ipc.Pipe, timed: bool) !void {
    const deadline_ms = try win32_ipc.decodeListWindowsDeadline(pipe, timed);
    const json = try requestAutomationWindowListJson(
        app,
        app.core_app.alloc,
        deadline_ms,
    );
    defer app.core_app.alloc.free(json);
    try win32_ipc.writeDataResponse(pipe, true, json);
}

fn handlePerformActionIpcClient(app: *App, pipe: win32_ipc.Pipe, timed: bool) !void {
    const payload = win32_ipc.decodePerformActionPayload(app.core_app.alloc, pipe, timed) catch |err| switch (err) {
        error.InvalidAutomationAction => {
            try win32_ipc.writeAckStatus(pipe, win32_ipc.ack_invalid_automation_action);
            return;
        },
        else => return err,
    };
    defer app.core_app.alloc.free(payload.action_text);
    try ackAutomationAction(app, pipe, payload.target, payload.action_text, payload.deadline_ms);
}

/// Run an automation action and answer the client: success, the status for
/// a refusal it can act on, or the error for `handleIpcClient` to report.
fn ackAutomationAction(
    app: *App,
    pipe: win32_ipc.Pipe,
    target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
    deadline_ms: u64,
) !void {
    requestAutomationAction(app, target, action_text, deadline_ms) catch |err| {
        const status: u8 = switch (err) {
            error.InvalidAutomationAction => win32_ipc.ack_invalid_automation_action,
            error.UnsafeAutomationAction => win32_ipc.ack_unsafe_automation_action,
            error.InvalidAutomationTarget => win32_ipc.ack_invalid_automation_target,
            error.NoAutomationTarget => win32_ipc.ack_no_automation_target,
            else => return err,
        };
        return win32_ipc.writeAckStatus(pipe, status);
    };
    try win32_ipc.writeAck(pipe, true);
}

fn handleLaunchLayoutIpcClient(app: *App, pipe: win32_ipc.Pipe, timed: bool) !void {
    const payload = win32_ipc.decodeLaunchLayoutPayload(app.core_app.alloc, pipe, timed) catch |err| {
        log.warn("invalid win32 launch-layout IPC request err={}", .{err});
        try win32_ipc.writeAckStatus(pipe, win32_ipc.ack_invalid_automation_action);
        return;
    };
    defer app.core_app.alloc.free(payload.name);

    // Name validation restricts this to an unambiguous action payload.
    const action_text = try std.fmt.allocPrint(
        app.core_app.alloc,
        "launch_layout:{s}",
        .{payload.name},
    );
    defer app.core_app.alloc.free(action_text);
    try ackAutomationAction(app, pipe, .focused, action_text, payload.deadline_ms);
}

fn handleFocusIpcClient(app: *App, pipe: win32_ipc.Pipe, timed: bool) !void {
    const payload = win32_ipc.decodeFocusPayload(pipe, timed) catch |err| switch (err) {
        error.InvalidAutomationTarget => {
            try win32_ipc.writeAckStatus(pipe, win32_ipc.ack_invalid_automation_target);
            return;
        },
        else => return err,
    };
    try ackAutomationCommand(app, pipe, .{ .focus = payload.target }, payload.deadline_ms);
}

fn handleSendTextIpcClient(app: *App, pipe: win32_ipc.Pipe, timed: bool) !void {
    var payload = win32_ipc.decodeSendTextPayload(app.core_app.alloc, pipe, timed) catch |err| switch (err) {
        error.InvalidAutomationText => {
            try win32_ipc.writeAckStatus(pipe, win32_ipc.ack_automation_policy_refused);
            return;
        },
        error.InvalidAutomationTarget => {
            try win32_ipc.writeAckStatus(pipe, win32_ipc.ack_invalid_automation_target);
            return;
        },
        else => return err,
    };
    defer payload.deinit(app.core_app.alloc);
    try ackAutomationCommand(app, pipe, .{ .send_text = .{
        .target = payload.target,
        .text = payload.text,
    } }, payload.deadline_ms);
}

/// Run an automation command and answer the client: success, the status
/// for a refusal it can act on, or the error for `handleIpcClient` to report.
fn ackAutomationCommand(
    app: *App,
    pipe: win32_ipc.Pipe,
    command: apprt.ipc.AutomationCommand,
    deadline_ms: u64,
) !void {
    requestAutomationCommand(app, command, deadline_ms) catch |err| {
        const status = automationCommandAckStatus(err) orelse return err;
        return win32_ipc.writeAckStatus(pipe, status);
    };
    try win32_ipc.writeAck(pipe, true);
}

fn automationCommandAckStatus(err: anyerror) ?u8 {
    return switch (err) {
        error.InvalidAutomationTarget, error.InvalidAutomationDirection => win32_ipc.ack_invalid_automation_target,
        error.AutomationTargetNotFound => win32_ipc.ack_automation_target_not_found,
        error.AutomationPolicyRefused, error.InvalidAutomationWorkingDirectory => win32_ipc.ack_automation_policy_refused,
        else => null,
    };
}

fn handleNewTabIpcClient(app: *App, pipe: win32_ipc.Pipe, timed: bool) !void {
    var payload = win32_ipc.decodeNewTabPayload(app.core_app.alloc, pipe, timed) catch |err| {
        const status = automationCommandAckStatus(err) orelse return err;
        try win32_ipc.writeAckStatus(pipe, status);
        return;
    };
    defer payload.deinit(app.core_app.alloc);
    if (payload.working_directory) |cwd| if (!automationWorkingDirectoryAllowed(cwd)) {
        try win32_ipc.writeAckStatus(pipe, win32_ipc.ack_automation_policy_refused);
        return;
    };
    try ackAutomationCommand(app, pipe, .{ .new_tab = .{
        .target = payload.target,
        .working_directory = payload.working_directory,
    } }, payload.deadline_ms);
}

fn handleNewSplitIpcClient(app: *App, pipe: win32_ipc.Pipe, timed: bool) !void {
    var payload = win32_ipc.decodeNewSplitPayload(app.core_app.alloc, pipe, timed) catch |err| {
        const status = automationCommandAckStatus(err) orelse return err;
        try win32_ipc.writeAckStatus(pipe, status);
        return;
    };
    defer payload.deinit(app.core_app.alloc);
    if (payload.working_directory) |cwd| if (!automationWorkingDirectoryAllowed(cwd)) {
        try win32_ipc.writeAckStatus(pipe, win32_ipc.ack_automation_policy_refused);
        return;
    };
    try ackAutomationCommand(app, pipe, .{ .new_split = .{
        .target = payload.target,
        .direction = payload.direction,
        .working_directory = payload.working_directory,
    } }, payload.deadline_ms);
}

/// Hand `message` to the App's mailbox, giving up after the IPC I/O timeout.
fn pushIpcMailboxMessage(app: *App, message: CoreApp.Message) bool {
    const mailbox: CoreApp.Mailbox = .{
        .rt_app = app,
        .mailbox = &app.core_app.mailbox,
    };
    return mailbox.push(message, .{ .ns = win32_ipc.io_timeout_ms * std.time.ns_per_ms }) != 0;
}

fn requestAutomationWindowListJson(
    app: *App,
    alloc: Allocator,
    client_deadline_ms: u64,
) ![]u8 {
    const request = try CoreApp.Message.AutomationWindowListRequest.create(
        alloc,
        serverAutomationDeadline(client_deadline_ms),
        automationNowMs,
    );
    defer request.release();
    request.retain(); // Mailbox-consumer ownership.
    if (!pushIpcMailboxMessage(app, .{ .automation_window_list = request })) {
        request.release();
        return error.IPCFailed;
    }

    try waitForAutomationCompletion(app, &request.lifecycle);
    if (request.err) |err| return err;
    return request.takeResult() orelse error.IPCFailed;
}

fn requestAutomationAction(
    app: *App,
    target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
    client_deadline_ms: u64,
) !void {
    if (action_text.len == 0 or action_text.len > win32_ipc.max_action_text_len) {
        return error.InvalidAutomationAction;
    }

    const request = try CoreApp.Message.AutomationActionRequest.create(
        app.core_app.alloc,
        target,
        action_text,
        serverAutomationDeadline(client_deadline_ms),
        automationNowMs,
    );
    defer request.release();
    request.retain(); // Mailbox-consumer ownership.
    if (!pushIpcMailboxMessage(app, .{ .automation_action = request })) {
        request.release();
        return error.IPCFailed;
    }

    try waitForAutomationCompletion(app, &request.lifecycle);
    if (request.err) |err| return err;
}

fn requestAutomationCommand(
    app: *App,
    command: apprt.ipc.AutomationCommand,
    client_deadline_ms: u64,
) !void {
    const request = try CoreApp.Message.AutomationCommandRequest.create(
        app.core_app.alloc,
        command,
        serverAutomationDeadline(client_deadline_ms),
        automationNowMs,
    );
    defer request.release();
    request.retain(); // Mailbox-consumer ownership.
    if (!pushIpcMailboxMessage(app, .{ .automation_command = request })) {
        request.release();
        return error.IPCFailed;
    }

    try waitForAutomationCompletion(app, &request.lifecycle);
    if (request.err) |err| return err;
}

fn waitForAutomationCompletion(
    app: *const App,
    lifecycle: *CoreApp.Message.AutomationRequestLifecycle,
) !void {
    while (true) {
        switch (lifecycle.load()) {
            .completed => return,
            .cancelled => return error.IPCFailed,
            .pending => {
                if (app.ipc_stop_requested.load(.acquire)) {
                    if (lifecycle.cancel()) return error.IPCFailed;
                } else if (automationNowMs() > lifecycle.deadline_ms) {
                    if (lifecycle.cancel()) return error.IpcTimeout;
                }
            },
            // Once the app thread has claimed a mutating request, the client
            // waits for its actual outcome instead of reporting a timeout that
            // could encourage a duplicate retry.
            .claimed => {},
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

fn automationNowMs() u64 {
    return sys.GetTickCount64();
}

fn serverAutomationDeadline(client_deadline_ms: u64) u64 {
    return @min(
        client_deadline_ms,
        automationNowMs() +| win32_ipc.automation_response_timeout_ms,
    );
}

/// The one argument a cold toast activation start forwards: the click's
/// launch string, rebuilt from what `Activate` delivered (the empty target
/// when nothing readable came, which the receiver presents as its primary
/// window). Caller owns the result.
fn coldToastForwardArgument(alloc: Allocator, activation: ?win32_toast_activation.ActivationTarget) ![:0]u8 {
    const launch = try win32_toast_activation.buildLaunchArg(alloc, activation orelse .{});
    defer alloc.free(launch);
    return alloc.dupeZ(u8, launch);
}

test "a cold toast activation start forwards the click, not its argv" {
    const alloc = std.testing.allocator;
    const target: win32_toast_activation.ActivationTarget = .{ .surface_id = 9, .tab_id = 2, .window_id = 1, .pid = 77, .action = .focus };
    for ([_]?win32_toast_activation.ActivationTarget{ target, .{}, null }) |sent| {
        const arg = try coldToastForwardArgument(alloc, sent);
        defer alloc.free(arg);
        // The receiver's new_window arm reads exactly this target, with
        // nothing else to drop or apply.
        const forwarded = [_][:0]const u8{arg};
        const received = win32.scanForwardedToastActivation(&forwarded);
        try std.testing.expect(received == .activation);
        try std.testing.expect((sent orelse win32_toast_activation.ActivationTarget{}).eql(received.activation));
        // It survives the sender's own normalization too.
        const normalized = (try normalizeForwardedStartupArg(alloc, arg)).?;
        defer alloc.free(normalized);
        try std.testing.expectEqualStrings(arg, normalized);
    }
}

pub fn tryForwardStartupToExistingInstance(self: *App) !bool {
    if (self.config.@"single-instance" != .true) return false;

    const pipe_name = try resolveIpcPipeName(self, self.core_app.alloc);
    defer self.core_app.alloc.free(pipe_name);

    if (try trySendStartupLaunchLayoutIpc(
        self.core_app.alloc,
        pipe_name,
        self.is_elevated,
        self.startup_launch_layout,
    )) |forwarded| return forwarded;

    // A cold start by the toast activator forwards the click, never its own
    // argv (`-ToastActivated -Embedding`), which would open a window there.
    if (self.toast_activated) {
        const launch_z = try coldToastForwardArgument(self.core_app.alloc, self.cold_toast_activation);
        defer self.core_app.alloc.free(launch_z);
        return try sendNewWindowIpc(
            self.core_app.alloc,
            pipe_name,
            self.is_elevated,
            &.{launch_z},
            win32_ipc.automation_response_timeout_ms,
        );
    }

    const arguments = try collectStartupForwardArguments(self.core_app.alloc);
    defer win32_ipc.freeOwnedArguments(self.core_app.alloc, arguments);

    return try sendNewWindowIpc(
        self.core_app.alloc,
        pipe_name,
        self.is_elevated,
        arguments,
        win32_ipc.automation_response_timeout_ms,
    );
}

/// Start the IPC server. Returns true only when a lost first-instance race
/// was resolved by forwarding this startup to the process that won it.
pub fn startIpcServer(self: *App) !bool {
    if (self.config.@"single-instance" != .true) return false;
    if (self.ipc_thread != null) return false;

    self.ipc_namespace = try sanitizeIpcNamespace(self.core_app.alloc, self.config.class);
    errdefer {
        if (self.ipc_namespace) |namespace| self.core_app.alloc.free(namespace);
        self.ipc_namespace = null;
    }

    const pipe_name = try resolveIpcPipeName(self, self.core_app.alloc);
    var pipe_name_owned = true;
    defer if (pipe_name_owned) self.core_app.alloc.free(pipe_name);

    // Both branches fail closed. With the DEFAULT named-pipe descriptor
    // the endpoint grants Administrators and LocalSystem full control,
    // grants Everyone read (enough to occupy instances and observe the
    // channel), and is reachable over SMB, so refuse to listen at all
    // rather than fall back to it. An elevated instance gets the stricter
    // owner-only DACL plus an `NRNW` high mandatory label; every other
    // instance gets the owner-pinned descriptor labelled with this
    // token's OWN integrity level.
    var pipe_security: win32_elevation.IpcPipeSecurity = security: {
        if (self.is_elevated) {
            break :security win32_elevation.initElevatedPipeSecurity(
                self.core_app.alloc,
            ) catch |err| {
                log.warn("failed to build elevated IPC pipe security; continuing without an IPC server err={}", .{err});
                return false;
            };
        }
        const descriptor = allocIpcPipeSecurityDescriptor() catch |err| {
            log.warn("failed to build win32 IPC pipe security descriptor; continuing without an IPC server err={}", .{err});
            return false;
        };
        break :security win32_elevation.adoptPipeSecurityDescriptor(descriptor);
    };
    var pipe_security_owned = true;
    defer if (pipe_security_owned) pipe_security.deinit();

    // Claim the name once, and act on the RESULT. Losing it means another
    // instance already owns this integrity-scoped name, which is the
    // ordinary single-instance case, not a failure.
    const first_pipe = createIpcServerPipe(
        pipe_name,
        pipe_security.securityAttributes(),
        true,
    );
    if (first_pipe == windows.INVALID_HANDLE_VALUE) {
        const create_error = windows.kernel32.GetLastError();
        if (win32_ipc.isIpcPipeClaimConflict(create_error)) {
            log.warn("win32 IPC pipe ownership claim failed err={}; retrying startup forward once", .{create_error});
            const forwarded = tryForwardStartupToExistingInstance(self) catch |err| failed: {
                log.warn("win32 IPC retry forward failed err={}", .{err});
                break :failed false;
            };
            if (forwarded) return true;
            log.warn("win32 IPC pipe remains owned by another process; continuing without an IPC server so this window can run locally", .{});
            return false;
        }

        log.warn("failed to create first win32 IPC pipe instance; continuing without an IPC server err={}", .{create_error});
        return false;
    }
    var first_pipe_owned = true;
    defer if (first_pipe_owned) {
        _ = windows.CloseHandle(first_pipe);
    };

    const io_event = createIpcServerEvent() orelse return false;
    var io_event_owned = true;
    defer if (io_event_owned) {
        _ = windows.CloseHandle(io_event);
    };
    const stop_event = createIpcServerEvent() orelse return false;
    errdefer _ = windows.CloseHandle(stop_event);

    self.ipc_pipe_name = pipe_name;
    errdefer self.ipc_pipe_name = null;
    self.ipc_stop_requested.store(false, .release);
    self.ipc_thread = try std.Thread.spawn(
        .{},
        ipcServerMain,
        .{ self, first_pipe, pipe_security, io_event, stop_event },
    );
    self.ipc_stop_event = stop_event;
    first_pipe_owned = false;
    pipe_security_owned = false;
    pipe_name_owned = false;
    io_event_owned = false;
    return false;
}

fn resolveIpcPipeName(self: *const App, alloc: Allocator) ![:0]const u16 {
    return allocIpcPipeName(alloc, self.config.class, self.is_elevated);
}

pub fn stopIpcServer(self: *App) void {
    if (self.ipc_thread) |thread| {
        self.ipc_stop_requested.store(true, .release);
        _ = sys.SetEvent(self.ipc_stop_event.?);
        thread.join();
        self.ipc_thread = null;
    }
    if (self.ipc_stop_event) |event| {
        _ = windows.CloseHandle(event);
        self.ipc_stop_event = null;
    }

    if (self.ipc_pipe_name) |pipe_name| {
        self.core_app.alloc.free(pipe_name);
        self.ipc_pipe_name = null;
    }
    if (self.ipc_namespace) |namespace| {
        self.core_app.alloc.free(namespace);
        self.ipc_namespace = null;
    }
    self.ipc_stop_requested.store(false, .release);
}

test "win32 sanitizeIpcNamespace normalizes invalid characters" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const actual = try sanitizeIpcNamespace(std.testing.allocator, "  team/alpha:*beta  ");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("team_alpha__beta", actual);
}

test "win32 elevated IPC pipe names are integrity scoped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const medium_name = try allocIpcPipeName(std.testing.allocator, "demo class", false);
    defer std.testing.allocator.free(medium_name);

    const medium_utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, medium_name[0..medium_name.len]);
    defer std.testing.allocator.free(medium_utf8);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\noctty.demo_class.medium", medium_utf8);

    const elevated_name = try allocIpcPipeName(std.testing.allocator, "demo class", true);
    defer std.testing.allocator.free(elevated_name);

    const elevated_utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, elevated_name[0..elevated_name.len]);
    defer std.testing.allocator.free(elevated_utf8);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\noctty.demo_class.elevated", elevated_utf8);

    const adversarial_medium = try allocIpcPipeName(std.testing.allocator, "demo class.elevated", false);
    defer std.testing.allocator.free(adversarial_medium);
    try std.testing.expect(!std.mem.eql(u16, adversarial_medium, elevated_name));
}

test "win32 normalizeForwardedStartupArg drops class and normalizes working directory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(try normalizeForwardedStartupArg(std.testing.allocator, "--class=dev") == null);
    try std.testing.expect(try normalizeForwardedStartupArg(std.testing.allocator, "--safe-mode") == null);

    const inherit = (try normalizeForwardedStartupArg(std.testing.allocator, "--working-directory=inherit")).?;
    defer std.testing.allocator.free(inherit);
    try std.testing.expectEqualStrings("--working-directory=inherit", inherit);

    const other = (try normalizeForwardedStartupArg(std.testing.allocator, "--title=Inbox")).?;
    defer std.testing.allocator.free(other);
    try std.testing.expectEqualStrings("--title=Inbox", other);

    const activation = (try normalizeForwardedStartupArg(
        std.testing.allocator,
        "wgh://activate?surface=42&tab=7",
    )).?;
    defer std.testing.allocator.free(activation);
    try std.testing.expectEqualStrings("wgh://activate?surface=42&tab=7", activation);

    try std.testing.expect(try normalizeForwardedStartupArg(
        std.testing.allocator,
        "wgh://activate?surface=abc",
    ) == null);
}

test "win32 synthesized forwarded working directory obeys receiver policy" {
    try std.testing.expect(try allocForwardedWorkingDirectoryArg(
        std.testing.allocator,
        "\\\\host\\share",
    ) == null);

    const local = (try allocForwardedWorkingDirectoryArg(
        std.testing.allocator,
        "C:\\work",
    )).?;
    defer std.testing.allocator.free(local);
    try std.testing.expectEqualStrings("--working-directory=C:\\work", local);
}

test "win32 new-window IPC rejects policy failures before acknowledgement" {
    try std.testing.expect(newWindowIpcArgumentsAccepted(null));
    try std.testing.expect(newWindowIpcArgumentsAccepted(&.{"--title=Inbox"}));
    try std.testing.expect(!newWindowIpcArgumentsAccepted(&.{"--command=calc.exe"}));
    try std.testing.expect(!newWindowIpcArgumentsAccepted(&.{
        "--working-directory=\\\\host\\share",
    }));
}

test "win32 timed out automation request stays owned and cannot be claimed" {
    const request = try CoreApp.Message.AutomationActionRequest.create(
        std.testing.allocator,
        .focused,
        "new_tab",
        std.math.maxInt(u64),
        automationNowMs,
    );
    request.retain();
    try std.testing.expect(request.lifecycle.cancel());
    request.release(); // Producer times out and drops its ownership.
    try std.testing.expectEqualStrings("new_tab", request.action_text);
    try std.testing.expect(!request.lifecycle.claim());
    request.release(); // Delayed mailbox consumer owns the final reference.
}

test "win32 IPC pipe SDDL renders the exact DACL and mandatory label" {
    const user_sid = std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-1111-2222-3333-1001");
    const medium_sid = std.unicode.utf8ToUtf16LeStringLiteral("S-1-16-8192");
    const high_sid = std.unicode.utf8ToUtf16LeStringLiteral("S-1-16-12288");

    var buf: [320]u16 = undefined;

    // Medium integrity is explicit so clients can reject an unlabeled
    // same-user squatter instead of treating it as implicitly medium.
    {
        const sddl = try buildIpcPipeSddl(&buf, user_sid, medium_sid);
        var utf8: [320]u8 = undefined;
        const len = try std.unicode.utf16LeToUtf8(&utf8, sddl);
        try std.testing.expectEqualStrings(
            "O:S-1-5-21-1111-2222-3333-1001" ++
                "D:P(A;;GA;;;S-1-5-21-1111-2222-3333-1001)" ++
                "S:(ML;;NW;;;S-1-16-8192)",
            utf8[0..len],
        );
    }

    // Above medium: the label ACE is what stops a filtered medium-integrity
    // token of the SAME user from opening the elevated instance's pipe for
    // write. The DACL alone cannot, because the token USER SID is identical
    // across the elevated and non-elevated tokens of one account.
    {
        const sddl = try buildIpcPipeSddl(&buf, user_sid, high_sid);
        var utf8: [320]u8 = undefined;
        const len = try std.unicode.utf16LeToUtf8(&utf8, sddl);
        try std.testing.expectEqualStrings(
            "O:S-1-5-21-1111-2222-3333-1001" ++
                "D:P(A;;GA;;;S-1-5-21-1111-2222-3333-1001)" ++
                "S:(ML;;NW;;;S-1-16-12288)",
            utf8[0..len],
        );
    }

    // A buffer too small to hold the text plus its sentinel fails closed.
    var tiny: [8]u16 = undefined;
    try std.testing.expectError(
        error.IpcSecurityDescriptorFailed,
        buildIpcPipeSddl(&tiny, user_sid, medium_sid),
    );
}

test "win32 integrity SID parsing accepts only mandatory label SIDs" {
    const expect = std.testing.expect;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    try std.testing.expectEqual(
        @as(?u32, 0x3000),
        integrityRidFromSidString(L("S-1-16-12288")),
    );
    try std.testing.expectEqual(
        @as(?u32, 0x2000),
        integrityRidFromSidString(L("S-1-16-8192")),
    );
    try std.testing.expectEqual(
        @as(?u32, 0x4000),
        integrityRidFromSidString(L("S-1-16-16384")),
    );

    // Anything that is not S-1-16-<digits> must fail closed rather than be
    // treated as an integrity level.
    try expect(integrityRidFromSidString(L("S-1-5-21-1-2-3-1001")) == null);
    try expect(integrityRidFromSidString(L("S-1-16-")) == null);
    try expect(integrityRidFromSidString(L("S-1-16-12a88")) == null);
    try expect(integrityRidFromSidString(L("")) == null);
    try expect(integrityRidFromSidString(L("S-1-16-99999999999")) == null);
}

test "win32 pipe descriptor integrity parsing accepts SDDL aliases" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqual(
        @as(u32, 0x3000),
        try descriptorIntegrityRidFromSddl(L("S:AI(ML;;NW;;;HI)")),
    );
    try std.testing.expectEqual(
        @as(u32, 0x4000),
        try descriptorIntegrityRidFromSddl(L("S:(ML;;NWNR;;;SI)")),
    );
    try std.testing.expectEqual(
        @as(u32, 0x3000),
        try descriptorIntegrityRidFromSddl(L("S:(ML;;NW;;;S-1-16-12288)")),
    );
    try std.testing.expectError(
        error.InvalidSecurityDescriptor,
        descriptorIntegrityRidFromSddl(L("")),
    );
    try std.testing.expectError(
        error.InvalidSecurityDescriptor,
        descriptorIntegrityRidFromSddl(L("S:(ML;;NW;;;ZZ)")),
    );
}

test "win32 SDDL auto-inherit normalization keeps every access-bearing field" {
    const alloc = std.testing.allocator;

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        // The exact shape CI produced on an elevated runner.
        .{
            .in = "D:P(A;;FA;;;LA)S:AI(ML;;NW;;;HI)",
            .want = "D:P(A;;FA;;;LA)S:(ML;;NW;;;HI)",
        },
        // Already normalized: unchanged.
        .{
            .in = "D:P(A;;FA;;;LA)S:(ML;;NW;;;HI)",
            .want = "D:P(A;;FA;;;LA)S:(ML;;NW;;;HI)",
        },
        // Medium integrity: no label, therefore no SACL at all.
        .{ .in = "D:P(A;;GA;;;S-1-5-21-1-2-3-1000)", .want = "D:P(A;;GA;;;S-1-5-21-1-2-3-1000)" },
        // AR as well as AI, and on both ACLs.
        .{ .in = "D:AIAR(A;;FA;;;LA)S:AR(ML;;NW;;;HI)", .want = "D:(A;;FA;;;LA)S:(ML;;NW;;;HI)" },
        // `P` survives -- losing it would silently allow an inheritable ACE.
        .{ .in = "D:PAI(A;;FA;;;LA)", .want = "D:P(A;;FA;;;LA)" },
        // Trustee aliases that merely CONTAIN A/I/R live inside ACEs, which the
        // flag scan never enters. AN (Anonymous) and AU are the ones that matter.
        .{ .in = "D:P(A;;FA;;;AN)(A;;FA;;;AU)", .want = "D:P(A;;FA;;;AN)(A;;FA;;;AU)" },
        // Owner and group sections are copied through untouched.
        .{ .in = "O:LAG:BAD:PAI(A;;FA;;;LA)", .want = "O:LAG:BAD:P(A;;FA;;;LA)" },
    };

    for (cases) |case| {
        const got = try testStripAclAutoInheritFlagsAlloc(alloc, case.in);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

/// A pipe name no other test uses: `\\.\pipe\noctty-ipc-<tag>-<tick>`.
fn testUniquePipeName(alloc: Allocator, comptime tag: []const u8) ![:0]u16 {
    const name = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\noctty-ipc-" ++ tag ++ "-{d}", .{sys.GetTickCount64()});
    defer alloc.free(name);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
}

/// A non-blocking byte pipe that rejects remote clients, with `descriptor`
/// attached.
fn testCreateSecuredPipe(name: [:0]const u16, descriptor: *anyopaque) windows.HANDLE {
    var security_attributes: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = descriptor,
        .bInheritHandle = windows.FALSE,
    };
    return sys.CreateNamedPipeW(
        name.ptr,
        c.PIPE_ACCESS_DUPLEX,
        windows.PIPE_TYPE_BYTE |
            c.PIPE_READMODE_BYTE |
            win32_ipc.pipe_nowait |
            c.PIPE_REJECT_REMOTE_CLIENTS,
        1,
        1024,
        1024,
        0,
        &security_attributes,
    );
}

test "win32 IPC pipe descriptor attaches the expected owner DACL and label" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const requested = try allocIpcPipeSecurityDescriptor();
    defer _ = sys.LocalFree(requested);

    const pipe_name = try testUniquePipeName(alloc, "sddl");
    defer alloc.free(pipe_name);

    // Assert against the descriptor Windows ACTUALLY ATTACHED, not against the
    // string we handed in. Only the live object shows the generic-rights
    // mapping, and only the live object proves the label survived creation.
    const pipe = testCreateSecuredPipe(pipe_name, requested);
    try std.testing.expect(pipe != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.CloseHandle(pipe);

    // DACL *and* label. Requesting the DACL alone would assert nothing about
    // the label, and would pass even if a label were wrongly emitted at medium
    // integrity. LABEL_SECURITY_INFORMATION needs no SeSecurityPrivilege.
    const information = c.OWNER_SECURITY_INFORMATION |
        c.DACL_SECURITY_INFORMATION |
        c.LABEL_SECURITY_INFORMATION;

    var attached: ?*anyopaque = null;
    const status = sys.GetSecurityInfo(
        pipe,
        c.SE_KERNEL_OBJECT,
        information,
        null,
        null,
        null,
        null,
        &attached,
    );
    try std.testing.expectEqual(@as(u32, 0), status);
    defer _ = sys.LocalFree(attached.?);

    const attached_text = try testDescriptorSddlAlloc(alloc, attached.?, information);
    defer alloc.free(attached_text);

    // Only the auto-inheritance bookkeeping the object manager stamps on the
    // attached copy is normalized away; every access-bearing field of the live
    // descriptor is compared exactly. See testStripAclAutoInheritFlagsAlloc.
    const actual = try testStripAclAutoInheritFlagsAlloc(alloc, attached_text);
    defer alloc.free(actual);

    // (1) What the pipe carries must equal what we asked for, once generic
    // rights are normalized and both sides are rendered the same way.
    {
        const requested_text = try testDescriptorSddlAlloc(alloc, requested, information);
        defer alloc.free(requested_text);
        const requested_mapped = try testMapGenericAllToFileAllAlloc(alloc, requested_text);
        defer alloc.free(requested_mapped);
        try std.testing.expectEqualStrings(requested_mapped, actual);
    }

    // (2) That alone would still pass if `allocIpcPipeSecurityDescriptor` were
    // changed to request a wider trustee, so rebuild the descriptor we WANT
    // independently from the token's own SID and require an exact match.
    var token: windows.HANDLE = undefined;
    try std.testing.expect(sys.OpenProcessToken(
        windows.kernel32.GetCurrentProcess(),
        c.TOKEN_QUERY,
        &token,
    ) != 0);
    defer _ = windows.CloseHandle(token);

    var token_user_buf: [256]u8 align(@alignOf(sys.TOKEN_USER)) = undefined;
    var token_user_len: u32 = 0;
    try std.testing.expect(sys.GetTokenInformation(
        token,
        c.TokenUser,
        &token_user_buf,
        token_user_buf.len,
        &token_user_len,
    ) != 0);
    const token_user: *const sys.TOKEN_USER = @ptrCast(&token_user_buf);

    var user_sid: ?[*:0]u16 = null;
    try std.testing.expect(sys.ConvertSidToStringSidW(
        token_user.User.Sid,
        &user_sid,
    ) != 0);
    defer _ = sys.LocalFree(@ptrCast(user_sid.?));

    const integrity_sid = try allocIpcPipeIntegritySid(token);
    defer _ = sys.LocalFree(@ptrCast(integrity_sid));

    var reference_buf: [320]u16 = undefined;
    const reference_sddl = try buildIpcPipeSddl(
        &reference_buf,
        std.mem.span(user_sid.?),
        std.mem.span(integrity_sid),
    );

    var reference: ?*anyopaque = null;
    try std.testing.expect(sys.ConvertStringSecurityDescriptorToSecurityDescriptorW(
        reference_sddl.ptr,
        c.SDDL_REVISION_1,
        &reference,
        null,
    ) != 0);
    defer _ = sys.LocalFree(reference.?);

    const reference_text = try testDescriptorSddlAlloc(alloc, reference.?, information);
    defer alloc.free(reference_text);
    const reference_mapped = try testMapGenericAllToFileAllAlloc(alloc, reference_text);
    defer alloc.free(reference_mapped);
    try std.testing.expectEqualStrings(reference_mapped, actual);

    // (3) Pin the SHAPE independently, so a future change to the SDDL we
    // request cannot quietly widen access while still matching (1) and (2).
    const dacl_idx = std.mem.indexOf(u8, actual, "D:") orelse
        return error.TestUnexpectedResult;
    const sacl_idx = std.mem.indexOf(u8, actual, "S:");
    const owner_text = actual[0..dacl_idx];
    const dacl_text = if (sacl_idx) |idx| actual[dacl_idx..idx] else actual[dacl_idx..];
    const sacl_text = if (sacl_idx) |idx| actual[idx..] else "";

    // The exact token-user owner was proved above. Its rendered SID shape is
    // environment-dependent (domain user, virtual account, or well-known
    // service alias), so only pin the owner field itself here.
    try std.testing.expect(owner_text.len > 2);
    try std.testing.expect(std.mem.startsWith(u8, owner_text, "O:"));
    try std.testing.expect(std.mem.startsWith(u8, dacl_text, "D:P"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, dacl_text, "(A;"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, dacl_text, "("));
    try std.testing.expect(std.mem.indexOf(u8, dacl_text, ";;;WD)") == null);
    try std.testing.expect(std.mem.indexOf(u8, dacl_text, ";;;AN)") == null);

    // Every endpoint must carry its exact label. An absent label is not
    // equivalent for authentication because Windows would interpret a
    // low-integrity squatter's unlabeled object as medium.
    try std.testing.expect(std.mem.startsWith(u8, sacl_text, "S:"));
    try std.testing.expect(std.mem.indexOf(u8, sacl_text, "(ML;;NW;;;") != null);
    const rid = integrityRidFromSidString(std.mem.span(integrity_sid)).?;
    try std.testing.expect(rid >= c.SECURITY_MANDATORY_LOW_RID);
}

test "win32 IPC pipe DACL still admits a same-user client" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const descriptor = try allocIpcPipeSecurityDescriptor();
    defer _ = sys.LocalFree(descriptor);

    const pipe_name = try testUniquePipeName(std.testing.allocator, "dacl");
    defer std.testing.allocator.free(pipe_name);

    const server = testCreateSecuredPipe(pipe_name, descriptor);
    try std.testing.expect(server != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.CloseHandle(server);

    // The CLI verbs reach the server through this same CreateFileW path,
    // so the restrictive DACL must not lock the owning user out.
    const client = windows.kernel32.CreateFileW(
        pipe_name.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    try std.testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.CloseHandle(client);
}

test "win32 forwarded new-window argv refuses everything off the allowlist" {
    const expect = std.testing.expect;

    // THE PROPERTY THAT MATTERS: the filter is deny-by-default, so a key
    // nobody enumerated -- including any key a future upstream merge adds --
    // is refused rather than allowed by omission. These names are not in the
    // allowlist and are not in any denylist either.
    try expect(!forwardedKeyAllowed("totally-made-up-key"));
    try expect(!forwardedKeyAllowed("some-future-upstream-key"));
    try expect(!forwardedKeyAllowed(""));

    // Each of these reproduces arbitrary code execution, an arbitrary file
    // read, an SMB authentication, or a pty write if it is honored.
    for ([_][]const u8{
        "command",
        "initial-command",
        "config-file",
        "config-default-files",
        "theme",
        "custom-shader",
        "gtk-custom-css",
        // Written straight to the pty; its doc comment warns it can execute
        // programs in a shell.
        "input",
        // Overrides are applied after shell-integration setup, so ZDOTDIR /
        // ENV / XDG_DATA_DIRS / PATH become code execution at shell start.
        "env",
        // Arbitrary file read, and a UNC value authenticates to a remote host.
        "background-image",
        "bell-audio-path",
        // Re-open the perform_action allowlist through another door.
        "keybind",
        "command-palette-entry",
        // Attacker bytes written to the pty on ENQ.
        "enquiry-response",
        // Not presentation.
        "title-report",
        "window-save-state",
        "class",
        "single-instance",
    }) |key| {
        try expect(!forwardedKeyAllowed(key));
    }

    // Prefix confusion must not admit anything: `windows-...` is a different
    // key from `window-...`.
    try expect(!forwardedKeyAllowed("windows-job-object-kill-on-close"));
    try expect(forwardedKeyAllowed("window-height"));

    // Representative allowlisted keys still work.
    for ([_][]const u8{
        "window-width",
        "window-height",
        "font-size",
        "title",
        "background",
        "background-opacity",
        "fullscreen",
        "maximize",
        "working-directory",
    }) |key| {
        try expect(forwardedKeyAllowed(key));
    }
}

test "win32 forwarded argv key extraction matches the config loader" {
    const expect = std.testing.expect;

    try std.testing.expectEqualStrings("font-size", forwardedArgumentKey("--font-size=14").?);
    try std.testing.expectEqualStrings("maximize", forwardedArgumentKey("--maximize").?);
    // Only the segment before the FIRST `=` is the key, matching
    // cli/args.zig.
    try std.testing.expectEqualStrings("title", forwardedArgumentKey("--title=a=b").?);
    try std.testing.expectEqualStrings("", forwardedArgumentKey("--=x").?);

    // Not `--key[=value]` form; these are refused wholesale by
    // `forwardedArgvRejection`.
    try expect(forwardedArgumentKey("-e") == null);
    try expect(forwardedArgumentKey("powershell") == null);
    try expect(forwardedArgumentKey("-") == null);

    // The keys a new window keeps over the state it copies: the exact key,
    // never a prefix or a value that happens to contain it.
    const argv: []const [:0]const u8 = &.{ "--window-width=80", "--title=--window-height=3", "--maximize" };
    try expect(forwardedArgvSetsKey(argv, "window-width"));
    try expect(forwardedArgvSetsKey(argv, "maximize"));
    try expect(!forwardedArgvSetsKey(argv, "window-height"));
    try expect(!forwardedArgvSetsKey(argv, "window"));
    try expect(!forwardedArgvSetsKey(&.{}, "window-width"));
}

test "win32 forwarded rejection reasons are classified and safe to log" {
    const argv_bad_key = [_][:0]const u8{"--input=calc.exe"};
    const r1 = forwardedArgvRejection(&argv_bad_key).?;
    try std.testing.expectEqual(.not_allowlisted, r1.reason);
    try std.testing.expectEqualStrings("input", r1.key);
    try std.testing.expect(forwardedKeyLoggable(r1.key));

    // `-e` becomes `initial-command` in Config.parseManuallyHook.
    const argv_dash_e = [_][:0]const u8{ "-e", "calc.exe" };
    try std.testing.expectEqual(
        .not_a_config_flag,
        forwardedArgvRejection(&argv_dash_e).?.reason,
    );

    const argv_wd = [_][:0]const u8{"--working-directory=\\\\attacker\\share"};
    try std.testing.expectEqual(
        .bad_working_directory,
        forwardedArgvRejection(&argv_wd).?.reason,
    );

    // A bad key later in the argv is still caught.
    const argv_trailing = [_][:0]const u8{ "--font-size=14", "--env=ZDOTDIR=C:\\a" };
    try std.testing.expectEqualStrings(
        "env",
        forwardedArgvRejection(&argv_trailing).?.key,
    );

    const argv_ok = [_][:0]const u8{ "--font-size=14", "--working-directory=home" };
    try std.testing.expect(forwardedArgvRejection(&argv_ok) == null);

    // A refused key is attacker-controlled text, so it must not be echoed
    // into a log line raw.
    try std.testing.expect(!forwardedKeyLoggable("has space"));
    try std.testing.expect(!forwardedKeyLoggable("newline\ninjected"));
    try std.testing.expect(!forwardedKeyLoggable("UPPER"));
    try std.testing.expect(!forwardedKeyLoggable("a" ** 65));
    try std.testing.expect(forwardedKeyLoggable("window-height"));
}

test "win32 forwarded working-directory rejects UNC syntax and keeps legal forms" {
    const expect = std.testing.expect;

    try expect(forwardedWorkingDirectoryAllowed("home"));
    try expect(forwardedWorkingDirectoryAllowed("inherit"));

    // Documented legal values that an earlier revision wrongly refused,
    // killing the whole +new-window request with only a log line.
    try expect(forwardedWorkingDirectoryAllowed("~"));
    try expect(forwardedWorkingDirectoryAllowed("~/projects"));
    try expect(forwardedWorkingDirectoryAllowed("~\\projects"));
    try expect(forwardedWorkingDirectoryAllowed("\"C:\\Program Files\\x\""));
    try expect(forwardedWorkingDirectoryAllowed("  C:\\Users\\me  "));

    // A literal UNC value would make this process authenticate to an
    // attacker-chosen SMB host. NOTE: this is a check on SYNTAX only -- a
    // mapped drive or a junction still resolves off-box.
    try expect(!forwardedWorkingDirectoryAllowed("\\\\attacker\\share"));
    try expect(!forwardedWorkingDirectoryAllowed("//attacker/share"));
    try expect(!forwardedWorkingDirectoryAllowed("\\\\?\\UNC\\attacker\\share"));
    try expect(!forwardedWorkingDirectoryAllowed("\\\\?\\C:\\Windows"));
    try expect(!forwardedWorkingDirectoryAllowed("\\\\.\\pipe\\x"));
    try expect(!forwardedWorkingDirectoryAllowed("relative\\path"));
    try expect(!forwardedWorkingDirectoryAllowed("C:foo"));
    try expect(!forwardedWorkingDirectoryAllowed(""));
    try expect(!forwardedWorkingDirectoryAllowed("\"\\\\attacker\\share\""));

    // A realpath'd local cwd is what the startup forwarder always sends, so
    // it has to keep working or single-instance launches break.
    if (builtin.os.tag == .windows) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.fs.cwd().realpath(".", &cwd_buf);
        try expect(forwardedWorkingDirectoryAllowed(cwd));
    }
}

test "win32 applyNewWindowArguments rejects a forwarded command outright" {
    const alloc = std.testing.allocator;

    // The whole request must be refused rather than silently stripping the
    // key, so the caller never builds a window from a half-honored argv.
    {
        var config = try configpkg.Config.default(alloc);
        defer config.deinit();
        try std.testing.expectError(
            error.ForbiddenForwardedArgument,
            applyNewWindowArguments(alloc, &config, &[_][:0]const u8{
                "--window-height=40",
                "--command=powershell -enc AAAA",
            }),
        );
        try std.testing.expect(config.command == null);
    }

    {
        var config = try configpkg.Config.default(alloc);
        defer config.deinit();
        try std.testing.expectError(
            error.ForbiddenForwardedArgument,
            applyNewWindowArguments(alloc, &config, &[_][:0]const u8{
                "--config-file=C:/tmp/evil.conf",
            }),
        );
    }

    // `--input` is written straight to the pty and its own doc comment warns
    // it can execute programs in a shell.
    {
        var config = try configpkg.Config.default(alloc);
        defer config.deinit();
        try std.testing.expectError(
            error.ForbiddenForwardedArgument,
            applyNewWindowArguments(alloc, &config, &[_][:0]const u8{
                "--input=powershell -enc AAAA\n",
            }),
        );
        try std.testing.expectEqual(@as(usize, 0), config.input.list.items.len);
    }

    // `--env` reaches the child after shell-integration setup, so it can
    // repoint ZDOTDIR/ENV and run an attacker script at shell start.
    {
        var config = try configpkg.Config.default(alloc);
        defer config.deinit();
        try std.testing.expectError(
            error.ForbiddenForwardedArgument,
            applyNewWindowArguments(alloc, &config, &[_][:0]const u8{
                "--env=ZDOTDIR=C:\\attacker",
            }),
        );
    }

    // Deny-by-default: a key that appears in NO list is still refused.
    {
        var config = try configpkg.Config.default(alloc);
        defer config.deinit();
        try std.testing.expectError(
            error.ForbiddenForwardedArgument,
            applyNewWindowArguments(alloc, &config, &[_][:0]const u8{
                "--some-key-nobody-enumerated=1",
            }),
        );
    }

    {
        var config = try configpkg.Config.default(alloc);
        defer config.deinit();
        try std.testing.expectError(
            error.ForbiddenForwardedArgument,
            applyNewWindowArguments(alloc, &config, &[_][:0]const u8{
                "--working-directory=\\\\attacker\\share",
            }),
        );
    }

    // A benign argv is still applied, including the working-directory the
    // startup forwarder always sends.
    {
        var config = try configpkg.Config.default(alloc);
        defer config.deinit();
        try applyNewWindowArguments(alloc, &config, &[_][:0]const u8{
            "--window-height=40",
            "--font-size=16",
            "--working-directory=home",
        });
        try std.testing.expectEqual(@as(u32, 40), config.@"window-height");
        try std.testing.expectEqual(@as(f32, 16), config.@"font-size");
    }
}

test "win32 IPC client authenticates the connected pipe descriptor" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    const pipe_name = try testUniquePipeName(alloc, "serverauth");
    defer alloc.free(pipe_name);

    const descriptor = try allocIpcPipeSecurityDescriptor();
    defer _ = sys.LocalFree(descriptor);

    const server = testCreateSecuredPipe(pipe_name, descriptor);
    try std.testing.expect(server != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.CloseHandle(server);

    // `connectToIpcPipe` performs the authentication itself, so connecting
    // to OUR OWN server succeeding is what proves the check ran and passed
    // rather than being skipped: if the SID comparison were broken in the
    // "reject" direction this returns `error.PipeUnreachable` instead.
    const client = try connectToIpcPipe(alloc, pipe_name, false);
    defer _ = windows.CloseHandle(client);

    // And directly, so a future refactor that drops the call site still
    // fails a test rather than silently disabling the check.
    try std.testing.expect(ipcPipeServerIsTrusted(client));

    // The comparison operates on a real, well-formed SID rather than an
    // empty slice that would trivially compare equal.
    var own_buf: SidBuffer align(sid_buffer_align) = undefined;
    const own_sid = try currentUserSidBytes(&own_buf);
    try std.testing.expect(own_sid.len >= 8);
    try std.testing.expectEqual(@as(u8, 1), own_sid[0]); // SID revision

    // The integrity half of the check reads a real level. A same-user SID
    // is NOT sufficient on its own, because a split UAC token shares it
    // across integrity levels.
    var token: windows.HANDLE = undefined;
    try std.testing.expect(sys.OpenProcessToken(
        windows.kernel32.GetCurrentProcess(),
        c.TOKEN_QUERY,
        &token,
    ) != 0);
    defer _ = windows.CloseHandle(token);
    const rid = tokenIntegrityRid(token).?;
    // Any interactive or service token sits at low or above; a zero here
    // would make the `>=` comparison vacuous.
    try std.testing.expect(rid >= c.SECURITY_MANDATORY_LOW_RID);

    // NOTE: the REJECT directions cannot be exercised here. A foreign-user
    // server needs a second local account, and a lower-integrity server
    // needs a medium process while this suite runs elevated; neither is
    // creatable from a test. Both are argued from the fail-closed structure
    // of `ipcPipeServerIsTrusted` (every error path returns false, and the
    // final comparison is `server_rid >= own_rid`), not observed.
}

test "automation working directory receiver policy mirrors forwarded syntax" {
    for ([_][]const u8{ "home", "inherit", "~", "~/x", "~\\x", "C:\\x" }) |value| {
        try std.testing.expect(automationWorkingDirectoryAllowed(value));
    }
    for ([_][]const u8{ "", "relative", "C:relative", "\\\\host\\share", "//host/share", "\\\\?\\C:\\x", "\\\\.\\x" }) |value| {
        try std.testing.expect(!automationWorkingDirectoryAllowed(value));
    }
}

test "win32 IPC silent synchronous client read is bounded" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pipe_name = try testUniquePipeName(std.testing.allocator, "timeout");
    defer std.testing.allocator.free(pipe_name);

    const server = sys.CreateNamedPipeW(
        pipe_name.ptr,
        c.PIPE_ACCESS_DUPLEX,
        windows.PIPE_TYPE_BYTE | c.PIPE_READMODE_BYTE | win32_ipc.pipe_nowait,
        1,
        1024,
        1024,
        0,
        null,
    );
    try std.testing.expect(server != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.CloseHandle(server);

    try std.testing.expectEqual(@as(BOOL, 0), sys.ConnectNamedPipe(server, null));
    try std.testing.expectEqual(windows.Win32Error.PIPE_LISTENING, windows.kernel32.GetLastError());

    const client = windows.kernel32.CreateFileW(
        pipe_name.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        win32_ipc.client_pipe_open_flags,
        null,
    );
    try std.testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.CloseHandle(client);
    try setIpcClientNonblocking(client);

    const connected = sys.ConnectNamedPipe(server, null);
    if (connected == 0) {
        try std.testing.expectEqual(windows.Win32Error.PIPE_CONNECTED, windows.kernel32.GetLastError());
    }

    var byte: [1]u8 = undefined;
    try std.testing.expectError(
        error.IpcTimeout,
        win32_ipc.readExactWithTimeout(client, &byte, 10),
    );
}

test "security regression win32 IPC server pipe mode rejects remote clients" {
    try std.testing.expectEqual(
        @as(u32, c.PIPE_REJECT_REMOTE_CLIENTS),
        @as(u32, ipc_server_pipe_mode & c.PIPE_REJECT_REMOTE_CLIENTS),
    );
}

test "security regression win32 IPC server claims the first pipe instance" {
    try std.testing.expectEqual(
        @as(u32, c.FILE_FLAG_FIRST_PIPE_INSTANCE),
        @as(u32, ipc_server_pipe_access & c.FILE_FLAG_FIRST_PIPE_INSTANCE),
    );
}

/// An App holding only the state `startIpcServer` and `stopIpcServer` read,
/// serving a pipe namespace unique to this process and server. No request in
/// these tests reaches the core mailbox, so `core_app` carries only the
/// allocator. Keep the value in place once started: `app` points into it.
const TestIpcServer = struct {
    var next_id: std.atomic.Value(u32) = .init(0);

    core_app: CoreApp = undefined,
    app: App = undefined,
    class_buf: [96:0]u8 = undefined,

    /// Set up the App without starting its server.
    fn prepare(self: *TestIpcServer) !void {
        const alloc = std.testing.allocator;
        self.core_app.alloc = alloc;
        self.app.core_app = &self.core_app;
        self.app.config = try configpkg.Config.default(alloc);
        errdefer self.app.config.deinit();
        self.app.config.@"single-instance" = .true;
        self.app.config.class = try std.fmt.bufPrintZ(
            &self.class_buf,
            "noctty-test-pkg67-{d}-{d}",
            .{ sys.GetCurrentProcessId(), next_id.fetchAdd(1, .monotonic) },
        );
        self.app.is_elevated = false;
        self.app.ipc_pipe_name = null;
        self.app.ipc_namespace = null;
        self.app.ipc_thread = null;
        self.app.ipc_stop_event = null;
        self.app.ipc_stop_requested = .init(false);
    }

    fn start(self: *TestIpcServer) !void {
        try self.prepare();
        errdefer self.app.config.deinit();
        try std.testing.expect(!try startIpcServer(&self.app));
        try std.testing.expect(self.app.ipc_thread != null);
    }

    fn stop(self: *TestIpcServer) void {
        stopIpcServer(&self.app);
        self.app.config.deinit();
    }

    fn connect(self: *TestIpcServer) !windows.HANDLE {
        return connectToIpcPipe(std.testing.allocator, self.app.ipc_pipe_name.?, false);
    }
};

extern "kernel32" fn QueryThreadCycleTime(thread: windows.HANDLE, cycles: *u64) callconv(.winapi) BOOL;
extern "kernel32" fn GetProcessHandleCount(process: windows.HANDLE, count: *u32) callconv(.winapi) BOOL;

fn testThreadCycles(thread: windows.HANDLE) !u64 {
    var cycles: u64 = 0;
    if (QueryThreadCycleTime(thread, &cycles) == 0) return error.TestUnexpectedResult;
    return cycles;
}

fn testProcessHandleCount() !u32 {
    var count: u32 = 0;
    if (GetProcessHandleCount(windows.kernel32.GetCurrentProcess(), &count) == 0) {
        return error.TestUnexpectedResult;
    }
    return count;
}

test "win32 IPC server thread does not busy-poll while it waits for a client" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var server: TestIpcServer = .{};
    try server.start();
    defer server.stop();
    const thread = server.app.ipc_thread.?.getHandle();

    // Require a full idle window, not a short "settled" sample: a thread
    // delayed during startup can look idle before it reaches the pipe wait.
    // Allow a bounded startup/retry budget for that or an incidental wakeup.
    // A 5 ms poll keeps accruing cycles in every 300 ms window and fails.
    var cycles = try testThreadCycles(thread);
    var cycle_deltas: [10]u64 = undefined;
    for (&cycle_deltas) |*delta| {
        std.Thread.sleep(300 * std.time.ns_per_ms);
        const now = try testThreadCycles(thread);
        delta.* = now - cycles;
        if (now == cycles) return;
        cycles = now;
    }
    std.debug.print("IPC server thread cycle deltas across 300 ms windows: {any}\n", .{cycle_deltas});
    return error.TestUnexpectedResult;
}

test "win32 IPC server replaces an instance whose client left before it was accepted" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var server: TestIpcServer = .{};
    try server.prepare();
    defer server.stop();
    const app = &server.app;

    // Claim the name as startIpcServer does, and let a client connect to the
    // first instance and leave before the server thread exists, so that its
    // first accept finds the client already gone.
    app.ipc_pipe_name = try allocIpcPipeName(std.testing.allocator, app.config.class, false);
    var security = win32_elevation.adoptPipeSecurityDescriptor(try allocIpcPipeSecurityDescriptor());
    var security_owned = true;
    defer if (security_owned) security.deinit();
    const first_pipe = createIpcServerPipe(app.ipc_pipe_name.?, security.securityAttributes(), true);
    try std.testing.expect(first_pipe != windows.INVALID_HANDLE_VALUE);
    var first_pipe_owned = true;
    defer if (first_pipe_owned) {
        _ = windows.CloseHandle(first_pipe);
    };
    const gone = windows.kernel32.CreateFileW(
        app.ipc_pipe_name.?.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        win32_ipc.client_pipe_open_flags,
        null,
    );
    try std.testing.expect(gone != windows.INVALID_HANDLE_VALUE);
    _ = windows.CloseHandle(gone);

    const io_event = createIpcServerEvent().?;
    var io_event_owned = true;
    defer if (io_event_owned) {
        _ = windows.CloseHandle(io_event);
    };
    app.ipc_stop_event = createIpcServerEvent().?;
    app.ipc_thread = try std.Thread.spawn(
        .{},
        ipcServerMain,
        .{ app, first_pipe, security, io_event, app.ipc_stop_event.? },
    );
    security_owned = false;
    first_pipe_owned = false;
    io_event_owned = false;

    // The next client is served: a request with a bad wire version is
    // answered with a failure ack before anything reaches the mailbox.
    const client = try server.connect();
    defer _ = windows.CloseHandle(client);
    try win32_ipc.writeAll(.{ .handle = client }, &.{ 0, 0, 0, 0, 1 });
    try std.testing.expectError(error.IPCFailed, win32_ipc.readAck(client));
}

test "win32 IPC server stops promptly while a client holds a request open" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var server: TestIpcServer = .{};
    try server.start();
    var stopped = false;
    defer if (!stopped) server.stop();

    // The client connects and sends nothing, so the server is waiting for
    // the request's first bytes when it is asked to stop.
    const client = try server.connect();
    defer _ = windows.CloseHandle(client);
    std.Thread.sleep(50 * std.time.ns_per_ms);

    const started = sys.GetTickCount64();
    server.stop();
    stopped = true;
    try std.testing.expect(sys.GetTickCount64() - started < 750);
}

test "win32 IPC server start and stop cycles leak no handles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // The first cycle loads whatever the pipe and token APIs keep open for
    // the life of the process.
    {
        var server: TestIpcServer = .{};
        try server.start();
        server.stop();
    }
    const before = try testProcessHandleCount();
    for (0..50) |_| {
        var server: TestIpcServer = .{};
        try server.start();
        server.stop();
    }
    try std.testing.expectEqual(before, try testProcessHandleCount());
}

test "win32 launch-layout IPC argument scan isolates the layout name" {
    const launch = try scanLaunchLayoutIpcArgument(&.{"--launch-layout=Project Alpha"});
    try std.testing.expectEqualStrings("Project Alpha", launch.name);

    try std.testing.expectError(
        error.MixedLaunchLayoutArguments,
        scanLaunchLayoutIpcArgument(&.{
            "--launch-layout=Project Alpha",
            "--title=other",
        }),
    );

    const ordinary = try scanLaunchLayoutIpcArgument(&.{"--title=ordinary"});
    try std.testing.expect(ordinary == .none);

    const command = try scanLaunchLayoutIpcArgument(&.{
        "-e",
        "tool.exe",
        "--launch-layout=child-option",
    });
    try std.testing.expect(command == .none);
}

test "win32 launch-layout IPC validates names before cold fallback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pipe_name = try std.unicode.utf8ToUtf16LeAllocZ(
        std.testing.allocator,
        "\\\\.\\pipe\\noctty.test.launch-layout-invalid-name",
    );
    defer std.testing.allocator.free(pipe_name);

    try std.testing.expectError(
        error.InvalidAutomationAction,
        sendLaunchLayoutIpc(
            std.testing.allocator,
            pipe_name,
            false,
            "CON",
            win32_ipc.automation_response_timeout_ms,
        ),
    );
}

test "win32 startup layout forwarding intercepts before generic argv" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pipe_name = try std.unicode.utf8ToUtf16LeAllocZ(
        std.testing.allocator,
        "\\\\.\\pipe\\noctty.test.startup-layout-invalid-name",
    );
    defer std.testing.allocator.free(pipe_name);

    try std.testing.expectEqual(
        @as(?bool, null),
        try trySendStartupLaunchLayoutIpc(std.testing.allocator, pipe_name, false, .none),
    );
    // Not forwarded, and not passed on to the generic argv either: this
    // process opens it, and `run` reports the failure in its own window.
    var invalid = "CON".*;
    try std.testing.expectEqual(
        @as(?bool, false),
        try trySendStartupLaunchLayoutIpc(std.testing.allocator, pipe_name, false, .{ .name = &invalid }),
    );
    // A request whose name was lost is still one: the generic argv forward
    // would open a plain window in the running instance.
    try std.testing.expectEqual(
        @as(?bool, false),
        try trySendStartupLaunchLayoutIpc(std.testing.allocator, pipe_name, false, .lost),
    );
}

test "win32 handleIpcClient bounds truncated request failures with an ack" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("ipc-request-truncated.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();

    var request: [4]u8 = undefined;
    std.mem.writeInt(u32, request[0..4], win32_ipc.wire_version, .little);
    try file.writeAll(&request);
    try file.seekTo(0);

    var app: App = undefined;
    try std.testing.expectError(error.EndOfStream, handleIpcClient(&app, .{ .handle = file.handle }));

    try file.seekTo(request.len);
    try std.testing.expectError(
        error.IPCFailed,
        win32_ipc.readDataResponse(std.testing.allocator, file.handle),
    );
}

/// Render a security descriptor to SDDL text.
///
/// Any two descriptors being compared must BOTH come through this one helper.
/// `ConvertSecurityDescriptorToStringSecurityDescriptorW` abbreviates a
/// well-known SID to its two-letter alias (`SY`, `BA`, `LA`, ...) while
/// `ConvertSidToStringSidW` always emits the full `S-1-5-...` form, so
/// rendering one side each way cannot be compared for any account that has an
/// alias -- which includes a runner executing as built-in Administrator or as
/// SYSTEM.
///
/// Helper shape borrowed from the equivalent fix on
/// `issues/123-paste-path-audit-fuzz` (`win32_ipc.zig` `descriptorSddlAlloc`);
/// keep the two in sync, or collapse them into one shared helper, when those
/// branches meet.
fn testDescriptorSddlAlloc(
    alloc: Allocator,
    descriptor: *anyopaque,
    information: u32,
) ![]u8 {
    var text: ?[*:0]u16 = null;
    if (sys.ConvertSecurityDescriptorToStringSecurityDescriptorW(
        descriptor,
        c.SDDL_REVISION_1,
        information,
        &text,
        null,
    ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());
    defer _ = sys.LocalFree(@ptrCast(text.?));

    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(text.?));
}

/// Rewrite `GENERIC_ALL` to `FILE_ALL_ACCESS` in SDDL text.
///
/// Windows resolves generic rights against the object's generic mapping when
/// an ACE is ATTACHED, so a descriptor built asking for `GA` reads back off a
/// named pipe as `FA`. Same access, canonical spelling. The request side has
/// to be normalized before it can be compared with what the object carries.
fn testMapGenericAllToFileAllAlloc(alloc: Allocator, sddl: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, alloc, sddl, ";;GA;;", ";;FA;;");
}

/// Drop the `AI` / `AR` ACL control flags from SDDL text.
///
/// `CreateNamedPipeW` hands our descriptor to the object manager, which runs
/// the auto-inheritance algorithm and stamps `SE_SACL_AUTO_INHERITED` on the
/// copy it attaches (the DACL escapes this only because we mark it protected).
/// `ConvertSecurityDescriptorToStringSecurityDescriptorW` then renders `S:AI(`
/// where the descriptor we asked for renders `S:(` — so a comparison of the two
/// spellings fails on any host that gets a label at all, i.e. an ELEVATED one.
/// That is why this only ever reproduced on CI: a medium-integrity developer
/// machine emits no label, so there is no SACL to stamp.
///
/// These two flags record how an ACL was assembled, never who may do what, so
/// normalizing them away loses no access-control coverage. `P` is deliberately
/// NOT stripped — assertion (3) below still requires a protected DACL.
fn testStripAclAutoInheritFlagsAlloc(alloc: Allocator, sddl: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < sddl.len) {
        // ACL flags only appear between an ACL introducer and its first ACE.
        if (!isTestSddlAclIntroducer(sddl, i)) {
            try out.append(alloc, sddl[i]);
            i += 1;
            continue;
        }

        try out.appendSlice(alloc, sddl[i .. i + 2]);
        i += 2;
        while (i < sddl.len and sddl[i] != '(' and !isTestSddlAclIntroducer(sddl, i)) {
            if (sddl[i] == 'A' and
                i + 1 < sddl.len and
                (sddl[i + 1] == 'I' or sddl[i + 1] == 'R'))
            {
                i += 2;
                continue;
            }
            try out.append(alloc, sddl[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(alloc);
}

fn isTestSddlAclIntroducer(sddl: []const u8, i: usize) bool {
    return (sddl[i] == 'D' or sddl[i] == 'S') and
        i + 1 < sddl.len and
        sddl[i + 1] == ':';
}
