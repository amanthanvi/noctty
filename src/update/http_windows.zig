//! Worker-owned HTTPS transport. Asynchronous WinHTTP requests let the worker
//! bound DNS/TCP/TLS, response-head and body waits without a second update worker.
//! Cancellation waits for HANDLE_CLOSING before freeing any callback or buffer.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const Handle = *anyopaque;
const WINAPI = std.builtin.CallingConvention.winapi;
const status_send_complete = 0x00400000;
const status_headers_available = 0x00020000;
const status_read_complete = 0x00080000;
const status_data_available = 0x00040000;
const status_request_error = 0x00200000;
const status_handle_closing = 0x00000800;

// winhttp.h
const access_type_no_proxy = 1;
const flag_async = 0x10000000;
const flag_secure = 0x00800000;
const secure_protocol_tls1_2 = 0x00000800;
const secure_protocol_tls1_3 = 0x00002000;
const option_context_value = 45;
const option_disable_feature = 63;
const option_secure_protocols = 84;
const option_max_response_header_size = 91;
const disable_cookies = 0x00000001;
const disable_redirects = 0x00000002;
const disable_authentication = 0x00000004;
const query_status_code = 19;
const query_flag_number = 0x20000000;
pub const query_content_encoding = 29;
pub const query_location = 33;
const error_winhttp_timeout = 12002; // WINHTTP_ERROR_BASE + 2
const error_winhttp_header_not_found = 12150; // WINHTTP_ERROR_BASE + 150
const error_invalid_parameter = 87; // winerror.h

pub const timeout_ms: i32 = 30_000;
pub const user_agent = "noctty-updater";

const Context = struct {
    complete: std.Thread.ResetEvent = .{},
    closing: std.Thread.ResetEvent = .{},
    closed: bool = false, // Worker-only; callbacks never access this field.
    err: ?u32 = null,
    read_len: usize = 0,
    limit_ms: i32,

    fn prepare(self: *Context) void {
        self.complete.reset();
        self.err = null;
        self.read_len = 0;
    }

    fn wait(self: *Context, request: Handle) !void {
        self.complete.timedWait(@as(u64, @intCast(self.limit_ms)) * std.time.ns_per_ms) catch {
            // In-flight async reads may still reference the caller's buffer.
            // Cancel and wait here, before any error can unwind that buffer.
            self.close(request);
            return error.UpdateHttpTimeout;
        };
        if (self.err) |code| return failureCode(code);
    }

    fn close(self: *Context, request: Handle) void {
        if (self.closed) return;
        self.closed = true;
        _ = WinHttpCloseHandle(request);
        self.closing.wait();
    }

    fn callback(_: Handle, opaque_context: usize, status: u32, info: ?*anyopaque, info_len: u32) callconv(WINAPI) void {
        if (opaque_context == 0) return;
        const self: *Context = @ptrFromInt(opaque_context);
        switch (status) {
            status_handle_closing => self.closing.set(),
            status_send_complete, status_headers_available => self.complete.set(),
            status_read_complete => {
                self.read_len = info_len;
                self.complete.set();
            },
            status_data_available => {
                self.read_len = @as(*const u32, @ptrCast(@alignCast(info.?))).*;
                self.complete.set();
            },
            status_request_error => {
                const Result = extern struct { result: usize, err: u32 };
                const result: *const Result = @ptrCast(@alignCast(info.?));
                self.err = result.err;
                self.complete.set();
            },
            else => {},
        }
    }
};

pub const Response = struct {
    session: Handle,
    connection: Handle,
    request: Handle,
    context: *Context,
    allocator: Allocator,
    status: std.http.Status,

    pub fn open(alloc: Allocator, uri: std.Uri, headers: []const std.http.Header) !Response {
        return openImpl(alloc, uri, headers, timeout_ms, true);
    }

    // Only the in-module wire tests use plaintext, avoiding any certificate
    // bypass or changes to the machine's trust store for the fake feed.
    fn openImpl(alloc: Allocator, uri: std.Uri, headers: []const std.http.Header, limit_ms: i32, secure: bool) !Response {
        if (!secure and !builtin.is_test) unreachable;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, if (secure) "https" else "http") or uri.user != null or uri.password != null)
            return error.InvalidUpdateUrl;
        var host_buf: [std.Uri.host_name_max]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        const host_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, host);
        defer alloc.free(host_w);
        var target: std.Io.Writer.Allocating = .init(alloc);
        defer target.deinit();
        try uri.writeToStream(&target.writer, .{ .path = true, .query = true });
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, target.written());
        defer alloc.free(target_w);

        // Match the old client's direct connection: no ambient proxy, cookies,
        // automatic credentials, or automatic redirects. Certificate and host
        // validation remain WinHTTP's secure defaults; no ignore flags are set.
        const session = WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral(user_agent), access_type_no_proxy, null, null, flag_async) orelse return failure();
        errdefer _ = WinHttpCloseHandle(session);
        if (WinHttpSetTimeouts(session, limit_ms, limit_ms, limit_ms, limit_ms) == 0) return failure();
        // Preserve the old TLS floor. Older Windows builds may reject TLS 1.3.
        var protocols: u32 = secure_protocol_tls1_2 | secure_protocol_tls1_3;
        if (WinHttpSetOption(session, option_secure_protocols, &protocols, @sizeOf(u32)) == 0) {
            if (@intFromEnum(windows.kernel32.GetLastError()) != error_invalid_parameter) return failure();
            protocols = secure_protocol_tls1_2;
            if (WinHttpSetOption(session, option_secure_protocols, &protocols, @sizeOf(u32)) == 0) return failure();
        }
        const connection = WinHttpConnect(session, host_w.ptr, uri.port orelse 443, 0) orelse return failure();
        errdefer _ = WinHttpCloseHandle(connection);
        const request = WinHttpOpenRequest(connection, std.unicode.utf8ToUtf16LeStringLiteral("GET"), target_w.ptr, null, null, null, if (secure) flag_secure else 0) orelse return failure();
        const context = alloc.create(Context) catch |err| {
            _ = WinHttpCloseHandle(request);
            return err;
        };
        context.* = .{ .limit_ms = limit_ms };
        errdefer alloc.destroy(context);
        var callback_bound = false;
        errdefer if (callback_bound) context.close(request) else {
            _ = WinHttpCloseHandle(request);
        };
        var context_value = @intFromPtr(context);
        if (WinHttpSetOption(request, option_context_value, &context_value, @sizeOf(usize)) == 0) return failure();
        const old_callback = WinHttpSetStatusCallback(request, Context.callback, status_send_complete | status_headers_available | status_read_complete | status_data_available | status_request_error | status_handle_closing, 0);
        if (old_callback != null and @intFromPtr(old_callback.?) == std.math.maxInt(usize)) return failure();
        callback_bound = true;
        var disable: u32 = disable_cookies | disable_redirects | disable_authentication;
        if (WinHttpSetOption(request, option_disable_feature, &disable, @sizeOf(u32)) == 0) return failure();
        var head_limit: u32 = 8192;
        if (WinHttpSetOption(request, option_max_response_header_size, &head_limit, @sizeOf(u32)) == 0) return failure();
        var header_text: std.Io.Writer.Allocating = .init(alloc);
        defer header_text.deinit();
        // Identity only: the feed's JSON is small and release assets are
        // already compressed, and refusing every other coding keeps update
        // bodies away from Zig 0.15.2's std.compress decoders (#570).
        try header_text.writer.writeAll("Accept-Encoding: identity\r\n");
        for (headers) |entry| {
            if (std.mem.indexOfAny(u8, entry.name, "\r\n:") != null or
                std.mem.indexOfAny(u8, entry.value, "\r\n") != null) return error.InvalidHttpHeader;
            try header_text.writer.print("{s}: {s}\r\n", .{ entry.name, entry.value });
        }
        const headers_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, header_text.written());
        defer alloc.free(headers_w);
        context.prepare();
        if (WinHttpSendRequest(request, headers_w.ptr, @intCast(headers_w.len), null, 0, 0, context_value) == 0) return failure();
        try context.wait(request);
        context.prepare();
        if (WinHttpReceiveResponse(request, null) == 0) return failure();
        try context.wait(request);
        var status: u32 = 0;
        var status_len: u32 = @sizeOf(u32);
        if (WinHttpQueryHeaders(request, query_status_code | query_flag_number, null, &status, &status_len, null) == 0) return failure();
        if (status > 999) return error.InvalidHttpStatus;
        return .{ .session = session, .connection = connection, .request = request, .context = context, .allocator = alloc, .status = @enumFromInt(status) };
    }

    pub fn deinit(self: *Response) void {
        self.context.close(self.request);
        self.allocator.destroy(self.context);
        _ = WinHttpCloseHandle(self.connection);
        _ = WinHttpCloseHandle(self.session);
        self.* = undefined;
    }

    pub fn header(self: *Response, alloc: Allocator, query: u32) !?[]u8 {
        return self.headerAt(alloc, query, null);
    }

    /// `index` selects one of several fields with the same name and is
    /// advanced past it, as `WinHttpQueryHeaders` does.
    fn headerAt(self: *Response, alloc: Allocator, query: u32, index: ?*u32) !?[]u8 {
        // The aggregate response head was already capped at 8 KiB above.
        var buffer: [8192]u16 = undefined;
        var len: u32 = @sizeOf(@TypeOf(buffer));
        if (WinHttpQueryHeaders(self.request, query, null, &buffer, &len, index) == 0) {
            if (@intFromEnum(windows.kernel32.GetLastError()) == error_winhttp_header_not_found) return null;
            return failure();
        }
        return try std.unicode.utf16LeToUtf8Alloc(alloc, buffer[0 .. len / 2]);
    }

    /// Requests ask for identity, so any other coding in any
    /// Content-Encoding field means a misbehaving server or proxy. Refuse it
    /// rather than decode it, or pass coded bytes on as the body.
    fn requireIdentityEncoding(self: *Response, alloc: Allocator) !void {
        var index: u32 = 0;
        while (try self.headerAt(alloc, query_content_encoding, &index)) |value| {
            defer alloc.free(value);
            var codings = std.mem.tokenizeAny(u8, value, ", \t");
            while (codings.next()) |coding| {
                if (!std.ascii.eqlIgnoreCase(coding, "identity")) return error.UnsupportedContentEncoding;
            }
        }
    }

    pub fn streamBody(self: *Response, alloc: Allocator, writer: *std.Io.Writer, max_bytes: u64) !void {
        try self.requireIdentityEncoding(alloc);
        var raw_reader: BodyReader = .{ .response = self };
        streamBounded(&raw_reader.interface, writer, max_bytes) catch |err| switch (err) {
            error.ReadFailed => return raw_reader.err orelse err,
            else => |other| return other,
        };
    }

    /// Read and drop a body nobody uses, such as a redirect's, under the
    /// same identity-only refusal and `max_bytes` bound as `streamBody`.
    pub fn discardBody(self: *Response, alloc: Allocator, max_bytes: u64) !void {
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        try self.streamBody(alloc, &discarding.writer, max_bytes);
    }

    pub fn read(self: *Response, buffer: []u8) !usize {
        if (self.context.closed) return error.UpdateHttpTimeout;
        if (buffer.len == 0) return 0;
        // Read only the bytes already available. Asking WinHttpReadData for a
        // full buffer can wait for later packets even while a slow download is
        // making progress, incorrectly turning this into a total-time limit.
        self.context.prepare();
        if (WinHttpQueryDataAvailable(self.request, null) == 0) return failure();
        try self.context.wait(self.request);
        const available = self.context.read_len;
        if (available == 0) return 0;
        self.context.prepare();
        // Async WinHTTP requires a null byte-count output; READ_COMPLETE owns it.
        if (WinHttpReadData(self.request, buffer.ptr, @intCast(@min(buffer.len, available)), null) == 0) return failure();
        try self.context.wait(self.request);
        return self.context.read_len;
    }
};

/// Pump `reader` into `writer`, refusing a body longer than `max_bytes`.
/// At most one byte past the cap reaches `writer` before the error, and
/// every caller discards its destination on error.
pub fn streamBounded(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    max_bytes: u64,
) !void {
    var streamed: u64 = 0;
    while (true) {
        const room = max_bytes + 1 - streamed;
        if (room == 0) return error.HttpResponseTooLarge;
        streamed += reader.stream(writer, .limited64(room)) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |other| return other,
        };
        if (streamed > max_bytes) return error.HttpResponseTooLarge;
    }
}

test "bounded response streaming refuses an oversized body" {
    const alloc = std.testing.allocator;
    const body = "0123456789";

    // Exactly at the cap is accepted.
    {
        var reader: std.Io.Reader = .fixed(body);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try streamBounded(&reader, &out.writer, body.len);
        try std.testing.expectEqualStrings(body, out.written());
    }

    // One byte over the cap is refused.
    {
        var reader: std.Io.Reader = .fixed(body);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.testing.expectError(
            error.HttpResponseTooLarge,
            streamBounded(&reader, &out.writer, body.len - 1),
        );
    }
}

const BodyReader = struct {
    response: *Response,
    err: ?anyerror = null,
    interface: std.Io.Reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },

    fn stream(io: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *BodyReader = @fieldParentPtr("interface", io);
        var buffer: [16 * 1024]u8 = undefined;
        const n = self.response.read(buffer[0..limit.minInt(buffer.len)]) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        try writer.writeAll(buffer[0..n]);
        return n;
    }
};

fn failure() error{ UpdateHttpTimeout, UpdateHttpTransportFailed } {
    return failureCode(@intFromEnum(windows.kernel32.GetLastError()));
}

fn failureCode(code: u32) error{ UpdateHttpTimeout, UpdateHttpTransportFailed } {
    return if (code == error_winhttp_timeout)
        error.UpdateHttpTimeout
    else
        error.UpdateHttpTransportFailed;
}

extern "winhttp" fn WinHttpOpen([*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(WINAPI) ?Handle;
extern "winhttp" fn WinHttpSetTimeouts(Handle, i32, i32, i32, i32) callconv(WINAPI) windows.BOOL;
extern "winhttp" fn WinHttpConnect(Handle, [*:0]const u16, u16, u32) callconv(WINAPI) ?Handle;
extern "winhttp" fn WinHttpOpenRequest(Handle, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?[*:null]const ?[*:0]const u16, u32) callconv(WINAPI) ?Handle;
extern "winhttp" fn WinHttpSetOption(Handle, u32, ?*anyopaque, u32) callconv(WINAPI) windows.BOOL;
extern "winhttp" fn WinHttpSetStatusCallback(Handle, *const fn (Handle, usize, u32, ?*anyopaque, u32) callconv(WINAPI) void, u32, usize) callconv(WINAPI) ?*anyopaque;
extern "winhttp" fn WinHttpSendRequest(Handle, ?[*]const u16, u32, ?*anyopaque, u32, u32, usize) callconv(WINAPI) windows.BOOL;
extern "winhttp" fn WinHttpReceiveResponse(Handle, ?*anyopaque) callconv(WINAPI) windows.BOOL;
extern "winhttp" fn WinHttpQueryHeaders(Handle, u32, ?[*:0]const u16, ?*anyopaque, *u32, ?*u32) callconv(WINAPI) windows.BOOL;
extern "winhttp" fn WinHttpReadData(Handle, [*]u8, u32, ?*u32) callconv(WINAPI) windows.BOOL;
extern "winhttp" fn WinHttpQueryDataAvailable(Handle, ?*u32) callconv(WINAPI) windows.BOOL;
extern "winhttp" fn WinHttpCloseHandle(Handle) callconv(WINAPI) windows.BOOL;

const FakePeer = struct {
    server: std.net.Server,
    mode: enum { tls, head, body, capture, progress },
    response: []const u8 = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
    fragment_bytes: usize = 0,
    stop: std.Thread.ResetEvent = .{},
    head: [4096]u8 = undefined,
    head_len: usize = 0,

    fn serve(self: *FakePeer) void {
        const conn = self.server.accept() catch return;
        defer conn.stream.close();
        if (self.stop.isSet()) return;
        if (self.mode == .tls) {
            self.stop.timedWait(2 * std.time.ns_per_s) catch {};
            return;
        }
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [256]u8 = undefined;
        var reader = conn.stream.reader(&read_buffer);
        var writer = conn.stream.writer(&write_buffer);
        var server = std.http.Server.init(reader.interface(), &writer.interface);
        const request = server.receiveHead() catch return;
        self.head_len = @min(request.head_buffer.len, self.head.len);
        @memcpy(self.head[0..self.head_len], request.head_buffer[0..self.head_len]);
        if (self.mode == .capture) {
            if (self.fragment_bytes != 0) {
                var offset: usize = 0;
                while (offset < self.response.len) {
                    // Split early framing byte by byte, including the first
                    // multi-digit chunk size and its CRLF; then fragment data.
                    const fragment_len: usize = if (offset < 128) 1 else self.fragment_bytes;
                    const end = @min(offset + fragment_len, self.response.len);
                    writer.interface.writeAll(self.response[offset..end]) catch return;
                    writer.interface.flush() catch return;
                    offset = end;
                    self.stop.timedWait(std.time.ns_per_ms) catch {};
                }
                return;
            }
            writer.interface.writeAll(self.response) catch return;
            writer.interface.flush() catch {};
            return;
        }
        if (self.mode == .progress) {
            writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\n") catch return;
            writer.interface.flush() catch return;
            for ("progress") |byte| {
                self.stop.timedWait(75 * std.time.ns_per_ms) catch {};
                writer.interface.writeByte(byte) catch return;
                writer.interface.flush() catch return;
            }
            return;
        }
        if (self.mode == .body) {
            writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nabc") catch return;
            writer.interface.flush() catch return;
        }
        // Finite fallback makes removing the timeout fail instead of hanging.
        self.stop.timedWait(2 * std.time.ns_per_s) catch {};
    }

    fn listenLoopback() !std.net.Server {
        return (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{});
    }

    fn finish(self: *FakePeer, thread: std.Thread) void {
        self.stop.set();
        // Also release accept if request setup failed before connecting.
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |stream| stream.close() else |_| {}
        thread.join();
        self.server.deinit();
    }

    fn uri(self: *FakePeer, buffer: []u8) !std.Uri {
        const url = try std.fmt.bufPrint(buffer, "{s}://127.0.0.1:{d}/fake-feed?escaped=%2F", .{
            @as([]const u8, if (self.mode == .tls) "https" else "http"), self.server.listen_address.getPort(),
        });
        return std.Uri.parse(url);
    }
};

/// `cap` is either the decoded body's length, which streams it whole, or one
/// byte short of it, which is refused.
fn expectBodyWithinCap(response: *Response, out: *std.Io.Writer.Allocating, contents: []const u8, cap: u64) !void {
    if (cap == contents.len) {
        try response.streamBody(out.allocator, &out.writer, cap);
        try std.testing.expectEqualSlices(u8, contents, out.written());
    } else {
        try std.testing.expectError(error.HttpResponseTooLarge, response.streamBody(out.allocator, &out.writer, cap));
    }
}

test "update HTTPS timeout interrupts stalled TLS and permits another request" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (0..2) |_| {
        var peer: FakePeer = .{ .server = try FakePeer.listenLoopback(), .mode = .tls };
        const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
        defer peer.finish(thread);
        var url: [256]u8 = undefined;
        var timer = try std.time.Timer.start();
        try std.testing.expectError(error.UpdateHttpTimeout, Response.openImpl(std.testing.allocator, try peer.uri(&url), &.{}, 100, true));
        try std.testing.expect(timer.read() < 1500 * std.time.ns_per_ms);
    }
}

test "update HTTP timeout interrupts stalled response headers and body" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    inline for (.{ .head, .body }) |mode| {
        var peer: FakePeer = .{ .server = try FakePeer.listenLoopback(), .mode = mode };
        const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
        defer peer.finish(thread);
        var url: [256]u8 = undefined;
        var timer = try std.time.Timer.start();
        if (mode == .head) {
            try std.testing.expectError(error.UpdateHttpTimeout, Response.openImpl(std.testing.allocator, try peer.uri(&url), &.{}, 100, false));
        } else {
            var response = try Response.openImpl(std.testing.allocator, try peer.uri(&url), &.{}, 100, false);
            defer response.deinit();
            var buffer: [16]u8 = undefined;
            while (response.read(&buffer)) |n| {
                try std.testing.expect(n != 0);
            } else |err| try std.testing.expectEqual(error.UpdateHttpTimeout, err);
        }
        try std.testing.expect(timer.read() < 1500 * std.time.ns_per_ms);
    }
}

test "update requests send exactly one User-Agent and accept only identity through the production transport" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var peer: FakePeer = .{ .server = try FakePeer.listenLoopback(), .mode = .capture };
    const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
    var finished = false;
    defer if (!finished) peer.finish(thread);
    var url: [256]u8 = undefined;
    var response = try Response.openImpl(std.testing.allocator, try peer.uri(&url), &.{.{ .name = "accept", .value = "application/octet-stream" }}, 1000, false);
    defer response.deinit();
    peer.finish(thread);
    finished = true;
    const head = peer.head[0..peer.head_len];
    try std.testing.expect(std.mem.startsWith(u8, head, "GET /fake-feed?escaped=%2F HTTP/1.1\r\n"));
    var user_agents: usize = 0;
    var accept_encodings: usize = 0;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "user-agent:")) {
            user_agents += 1;
            try std.testing.expectEqualStrings("User-Agent: noctty-updater", line);
        }
        if (std.ascii.startsWithIgnoreCase(line, "accept-encoding:")) {
            accept_encodings += 1;
            try std.testing.expectEqualStrings("Accept-Encoding: identity", line);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), user_agents);
    try std.testing.expectEqual(@as(usize, 1), accept_encodings);
    try std.testing.expect(std.mem.indexOf(u8, head, "Accept: application/octet-stream") != null or std.mem.indexOf(u8, head, "accept: application/octet-stream") != null);
}

test "update HTTP transport refuses every content coding but identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const contents = "fake update metadata";
    // `contents` gzipped: a server that ignores the request's identity-only
    // Accept-Encoding gets refused, not decoded.
    const gzip_bytes = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x4b\x4b\xcc\x4e\x55\x28\x2d\x48\x49\x2c\x49\x55\xc8\x4d\x2d\x49\x04\x32\x12\x01\xb6\x57\x0f\xe1\x14\x00\x00\x00";
    for ([_]struct { fields: []const u8, bytes: []const u8, refused: bool }{
        .{ .fields = "Content-Encoding: gzip\r\n", .bytes = gzip_bytes, .refused = true },
        .{ .fields = "Content-Encoding: x-gzip\r\n", .bytes = gzip_bytes, .refused = true },
        .{ .fields = "Content-Encoding: deflate\r\n", .bytes = contents, .refused = true },
        .{ .fields = "Content-Encoding: zstd\r\n", .bytes = contents, .refused = true },
        .{ .fields = "Content-Encoding: br\r\n", .bytes = contents, .refused = true },
        .{ .fields = "Content-Encoding: identity, gzip\r\n", .bytes = gzip_bytes, .refused = true },
        // Only the second field names a coding.
        .{ .fields = "Content-Encoding: identity\r\nContent-Encoding: gzip\r\n", .bytes = gzip_bytes, .refused = true },
        .{ .fields = "", .bytes = contents, .refused = false },
        .{ .fields = "Content-Encoding: IDENTITY\r\n", .bytes = contents, .refused = false },
    }) |case| {
        const reply = try std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ case.fields, case.bytes.len, case.bytes });
        defer alloc.free(reply);
        var peer: FakePeer = .{ .server = try FakePeer.listenLoopback(), .mode = .capture, .response = reply };
        const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
        defer peer.finish(thread);
        var url: [256]u8 = undefined;
        var response = try Response.openImpl(alloc, try peer.uri(&url), &.{}, 1000, false);
        defer response.deinit();
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        if (case.refused) {
            try std.testing.expectError(error.UnsupportedContentEncoding, response.streamBody(alloc, &out.writer, 1024));
            try std.testing.expectEqual(@as(usize, 0), out.written().len);
        } else {
            try expectBodyWithinCap(&response, &out, contents, contents.len);
        }
    }
}

test "update HTTP redirect bodies are discarded under the same coding refusal and bound" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const redirect = "HTTP/1.1 302 Found\r\nLocation: https://example.invalid/next\r\n";
    for ([_]struct { reply: []const u8, cap: u64, err: ?anyerror }{
        .{ .reply = redirect ++ "Content-Encoding: gzip\r\nContent-Length: 8\r\nConnection: close\r\n\r\nredirect", .cap = 1024, .err = error.UnsupportedContentEncoding },
        .{ .reply = redirect ++ "Content-Length: 8\r\nConnection: close\r\n\r\nredirect", .cap = 8, .err = null },
        .{ .reply = redirect ++ "Content-Length: 8\r\nConnection: close\r\n\r\nredirect", .cap = 7, .err = error.HttpResponseTooLarge },
    }) |case| {
        var peer: FakePeer = .{ .server = try FakePeer.listenLoopback(), .mode = .capture, .response = case.reply };
        const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
        defer peer.finish(thread);
        var url: [256]u8 = undefined;
        var response = try Response.openImpl(alloc, try peer.uri(&url), &.{}, 1000, false);
        defer response.deinit();
        try std.testing.expectEqual(std.http.Status.found, response.status);
        if (case.err) |err| {
            try std.testing.expectError(err, response.discardBody(alloc, case.cap));
        } else {
            try response.discardBody(alloc, case.cap);
        }
    }
}

test "update HTTP transport decodes fragmented chunked replies across reader boundaries" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const contents = try alloc.alloc(u8, 48 * 1024 + 17);
    defer alloc.free(contents);
    for (contents, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% (i / 251));
    var reply: std.Io.Writer.Allocating = .init(alloc);
    defer reply.deinit();
    try reply.writer.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
    var offset: usize = 0;
    for ([_]usize{ 1, 16383, 16385, 73, contents.len - 32842 }) |chunk_len| {
        try reply.writer.print("{x}\r\n", .{chunk_len});
        try reply.writer.writeAll(contents[offset..][0..chunk_len]);
        try reply.writer.writeAll("\r\n");
        offset += chunk_len;
    }
    try std.testing.expectEqual(contents.len, offset);
    try reply.writer.writeAll("0\r\n\r\n");
    for ([_]usize{ contents.len, contents.len - 1 }) |cap| {
        var peer: FakePeer = .{
            .server = try FakePeer.listenLoopback(),
            .mode = .capture,
            .response = reply.written(),
            // Split chunk lengths, CRLFs and payloads across separate writes.
            .fragment_bytes = 257,
        };
        const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
        defer peer.finish(thread);
        var url: [256]u8 = undefined;
        // This tests framing, not deadlines. Bytewise writes can each wait a
        // whole Windows timer tick even though the peer requests only 1 ms.
        var response = try Response.openImpl(alloc, try peer.uri(&url), &.{}, 5000, false);
        defer response.deinit();
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try expectBodyWithinCap(&response, &out, contents, cap);
    }
}

test "update HTTP transport bounds aggregate headers and leaves redirects to HTTPS policy" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |oversized| {
        var peer: FakePeer = .{
            .server = try FakePeer.listenLoopback(),
            .mode = .capture,
            .response = if (oversized)
                "HTTP/1.1 200 OK\r\nX-Padding: " ++ "x" ** 9000 ++ "\r\nContent-Length: 0\r\n\r\n"
            else
                "HTTP/1.1 302 Found\r\nLocation: http://example.invalid/no-plaintext-redirect\r\nContent-Length: 0\r\n\r\n",
        };
        const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
        defer peer.finish(thread);
        var url: [256]u8 = undefined;
        if (oversized) {
            try std.testing.expectError(error.UpdateHttpTransportFailed, Response.openImpl(alloc, try peer.uri(&url), &.{}, 1000, false));
        } else {
            var response = try Response.openImpl(alloc, try peer.uri(&url), &.{}, 1000, false);
            defer response.deinit();
            try std.testing.expectEqual(std.http.Status.found, response.status);
            const location = (try response.header(alloc, query_location)).?;
            defer alloc.free(location);
            try std.testing.expectEqualStrings("http://example.invalid/no-plaintext-redirect", location);
        }
    }
}

test "update HTTP body reads reset the deadline while a slow fake feed progresses" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var peer: FakePeer = .{ .server = try FakePeer.listenLoopback(), .mode = .progress };
    const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
    defer peer.finish(thread);
    var url: [256]u8 = undefined;
    var response = try Response.openImpl(alloc, try peer.uri(&url), &.{}, 400, false);
    defer response.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var timer = try std.time.Timer.start();
    try response.streamBody(alloc, &out.writer, 8);
    try std.testing.expectEqualStrings("progress", out.written());
    try std.testing.expect(timer.read() > 400 * std.time.ns_per_ms);
}
