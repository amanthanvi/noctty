//! Worker-owned HTTPS transport. Asynchronous WinHTTP requests let the worker
//! bound DNS/TCP/TLS, response-head and body waits without a second update worker.
//! Cancellation waits for HANDLE_CLOSING before freeing any callback or buffer.
const std = @import("std");
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
        return openWithTimeout(alloc, uri, headers, timeout_ms);
    }

    fn openWithTimeout(alloc: Allocator, uri: std.Uri, headers: []const std.http.Header, limit_ms: i32) !Response {
        return openImpl(alloc, uri, headers, limit_ms, true);
    }

    // Only the in-module wire tests use plaintext, avoiding any certificate
    // bypass or changes to the machine's trust store for the fake feed.
    fn openImpl(alloc: Allocator, uri: std.Uri, headers: []const std.http.Header, limit_ms: i32, secure: bool) !Response {
        if (!secure and !@import("builtin").is_test) unreachable;
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
        const session = WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral(user_agent), 1, null, null, 0x10000000) orelse return failure();
        errdefer _ = WinHttpCloseHandle(session);
        if (WinHttpSetTimeouts(session, limit_ms, limit_ms, limit_ms, limit_ms) == 0) return failure();
        // Preserve the old TLS floor. Older Windows builds may reject TLS 1.3.
        var protocols: u32 = 0x800 | 0x2000;
        if (WinHttpSetOption(session, 84, &protocols, @sizeOf(u32)) == 0) {
            if (@intFromEnum(windows.kernel32.GetLastError()) != 87) return failure();
            protocols = 0x800;
            if (WinHttpSetOption(session, 84, &protocols, @sizeOf(u32)) == 0) return failure();
        }
        const connection = WinHttpConnect(session, host_w.ptr, uri.port orelse 443, 0) orelse return failure();
        errdefer _ = WinHttpCloseHandle(connection);
        const request = WinHttpOpenRequest(connection, std.unicode.utf8ToUtf16LeStringLiteral("GET"), target_w.ptr, null, null, null, if (secure) 0x00800000 else 0) orelse return failure();
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
        if (WinHttpSetOption(request, 45, &context_value, @sizeOf(usize)) == 0) return failure();
        const old_callback = WinHttpSetStatusCallback(request, Context.callback, status_send_complete | status_headers_available | status_read_complete | status_data_available | status_request_error | status_handle_closing, 0);
        if (old_callback != null and @intFromPtr(old_callback.?) == std.math.maxInt(usize)) return failure();
        callback_bound = true;
        var disable: u32 = 1 | 2 | 4; // cookies, redirects, authentication
        if (WinHttpSetOption(request, 63, &disable, @sizeOf(u32)) == 0) return failure();
        var head_limit: u32 = 8192;
        if (WinHttpSetOption(request, 91, &head_limit, @sizeOf(u32)) == 0) return failure();
        var header_text: std.Io.Writer.Allocating = .init(alloc);
        defer header_text.deinit();
        try header_text.writer.writeAll("Accept-Encoding: gzip, deflate, identity\r\n");
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
        if (WinHttpQueryHeaders(request, 19 | 0x20000000, null, &status, &status_len, null) == 0) return failure();
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
        // The aggregate response head was already capped at 8 KiB above.
        var buffer: [8192]u16 = undefined;
        var len: u32 = @sizeOf(@TypeOf(buffer));
        if (WinHttpQueryHeaders(self.request, query, null, &buffer, &len, null) == 0) {
            if (@intFromEnum(windows.kernel32.GetLastError()) == 12150) return null;
            return failure();
        }
        return try std.unicode.utf16LeToUtf8Alloc(alloc, buffer[0 .. len / 2]);
    }

    pub fn streamBody(self: *Response, alloc: Allocator, writer: *std.Io.Writer, max_bytes: u64) !void {
        const encoding_text = try self.header(alloc, 29);
        defer if (encoding_text) |text| alloc.free(text);
        const encoding: std.http.ContentEncoding = if (encoding_text) |text|
            std.http.ContentEncoding.fromString(text) orelse return error.UnsupportedCompressionMethod
        else
            .identity;
        const decompress_buffer: []u8 = switch (encoding) {
            .identity => &.{},
            .zstd => try alloc.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try alloc.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer.len > 0) alloc.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var raw_reader: BodyReader = .{ .response = self };
        raw_reader.interface.buffer = &transfer_buffer;
        var decompress: std.http.Decompress = undefined;
        const body_reader = decompress.init(&raw_reader.interface, decompress_buffer, encoding);
        streamBounded(body_reader, writer, max_bytes) catch |err| switch (err) {
            error.ReadFailed => return raw_reader.err orelse err,
            else => |other| return other,
        };
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
    return if (code == 12002)
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

test "update HTTPS timeout interrupts stalled TLS and permits another request" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    for (0..2) |_| {
        var peer: FakePeer = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}), .mode = .tls };
        const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
        defer peer.finish(thread);
        var url: [256]u8 = undefined;
        var timer = try std.time.Timer.start();
        try std.testing.expectError(error.UpdateHttpTimeout, Response.openWithTimeout(std.testing.allocator, try peer.uri(&url), &.{}, 100));
        try std.testing.expect(timer.read() < 1500 * std.time.ns_per_ms);
    }
}

test "update HTTP timeout interrupts stalled response headers and body" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    inline for (.{ .head, .body }) |mode| {
        var peer: FakePeer = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}), .mode = mode };
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

test "update requests send exactly one User-Agent through the production transport" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var peer: FakePeer = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}), .mode = .capture };
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
    var count: usize = 0;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "user-agent:")) {
            count += 1;
            try std.testing.expectEqualStrings("User-Agent: noctty-updater", line);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, head, "Accept: application/octet-stream") != null or std.mem.indexOf(u8, head, "accept: application/octet-stream") != null);
}

test "update HTTP transport decodes gzip aliases and deflate with the decompressed cap" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const contents = "fake update metadata";
    const gzip_bytes = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x4b\x4b\xcc\x4e\x55\x28\x2d\x48\x49\x2c\x49\x55\xc8\x4d\x2d\x49\x04\x32\x12\x01\xb6\x57\x0f\xe1\x14\x00\x00\x00";
    const deflate_bytes = "\x78\x9c\x4b\x4b\xcc\x4e\x55\x28\x2d\x48\x49\x2c\x49\x55\xc8\x4d\x2d\x49\x04\x32\x12\x01\x4e\xe7\x07\x9c";
    for ([_]struct { encoding: []const u8, bytes: []const u8 }{
        .{ .encoding = "gzip", .bytes = gzip_bytes },
        .{ .encoding = "x-gzip", .bytes = gzip_bytes },
        .{ .encoding = "deflate", .bytes = deflate_bytes },
    }) |case| {
        for ([_]u64{ contents.len, contents.len - 1 }) |cap| {
            const reply = try std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Encoding: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ case.encoding, case.bytes.len, case.bytes });
            defer alloc.free(reply);
            var peer: FakePeer = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}), .mode = .capture, .response = reply };
            const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
            defer peer.finish(thread);
            var url: [256]u8 = undefined;
            var response = try Response.openImpl(alloc, try peer.uri(&url), &.{}, 1000, false);
            defer response.deinit();
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            if (cap == contents.len) {
                try response.streamBody(alloc, &out.writer, cap);
                try std.testing.expectEqualStrings(contents, out.written());
            } else {
                try std.testing.expectError(error.HttpResponseTooLarge, response.streamBody(alloc, &out.writer, cap));
            }
        }
    }
}

test "update HTTP transport decodes a large gzip body across reader boundaries" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const contents = try alloc.alloc(u8, 48 * 1024 + 17);
    defer alloc.free(contents);
    var random = std.Random.DefaultPrng.init(0x706b673632);
    random.random().bytes(contents);
    var compressed: std.Io.Writer.Allocating = .init(alloc);
    defer compressed.deinit();
    // A gzip member with one stored DEFLATE block keeps the encoded fixture
    // larger than 16 KiB without relying on Zig 0.15's unfinished compressor.
    try compressed.writer.writeAll("\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x01");
    var lengths: [4]u8 = undefined;
    const block_len: u16 = @intCast(contents.len);
    std.mem.writeInt(u16, lengths[0..2], block_len, .little);
    std.mem.writeInt(u16, lengths[2..4], ~block_len, .little);
    try compressed.writer.writeAll(&lengths);
    try compressed.writer.writeAll(contents);
    var footer: [8]u8 = undefined;
    std.mem.writeInt(u32, footer[0..4], std.hash.Crc32.hash(contents), .little);
    std.mem.writeInt(u32, footer[4..8], @intCast(contents.len), .little);
    try compressed.writer.writeAll(&footer);
    // Both encoded and decoded data must span the transport's 16 KiB buffer.
    try std.testing.expect(compressed.written().len > 16 * 1024);
    const reply = try std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ compressed.written().len, compressed.written() });
    defer alloc.free(reply);
    for ([_]usize{ contents.len, contents.len - 1 }) |cap| {
        var peer: FakePeer = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}), .mode = .capture, .response = reply };
        const thread = try std.Thread.spawn(.{}, FakePeer.serve, .{&peer});
        defer peer.finish(thread);
        var url: [256]u8 = undefined;
        var response = try Response.openImpl(alloc, try peer.uri(&url), &.{}, 1000, false);
        defer response.deinit();
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        if (cap == contents.len) {
            try response.streamBody(alloc, &out.writer, cap);
            try std.testing.expectEqualSlices(u8, contents, out.written());
        } else {
            try std.testing.expectError(error.HttpResponseTooLarge, response.streamBody(alloc, &out.writer, cap));
        }
    }
}

test "update HTTP transport decodes fragmented chunked replies across reader boundaries" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
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
            .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}),
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
        if (cap == contents.len) {
            try response.streamBody(alloc, &out.writer, cap);
            try std.testing.expectEqualSlices(u8, contents, out.written());
        } else {
            try std.testing.expectError(error.HttpResponseTooLarge, response.streamBody(alloc, &out.writer, cap));
        }
    }
}

test "update HTTP transport bounds aggregate headers and leaves redirects to HTTPS policy" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |oversized| {
        var peer: FakePeer = .{
            .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}),
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
            const location = (try response.header(alloc, 33)).?;
            defer alloc.free(location);
            try std.testing.expectEqualStrings("http://example.invalid/no-plaintext-redirect", location);
        }
    }
}

test "update HTTP body reads reset the deadline while a slow fake feed progresses" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var peer: FakePeer = .{ .server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}), .mode = .progress };
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
