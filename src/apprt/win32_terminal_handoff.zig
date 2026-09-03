//! Windows default-terminal registration and the ITerminalHandoff3 local
//! server. noctty intentionally implements only the terminal half; the
//! console half remains a compatible Windows Terminal OpenConsole process.

const std = @import("std");
const windows = std.os.windows;
const ptypkg = @import("../pty.zig");
const com = @import("win32_uia/com.zig");

const log = std.log.scoped(.win32_terminal_handoff);
const Allocator = std.mem.Allocator;
const HRESULT = com.HRESULT;
const GUID = com.GUID;
const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPCWSTR = ?[*:0]const u16;
const HKEY = *opaque {};
const LSTATUS = i32;

pub const clsid_text = "{33368C6F-D328-410C-B225-26DC9F12C728}";
pub const proxy_clsid_text = "{1D349824-21FB-46C7-ACF3-746EDC991D52}";
pub const proxy_filename = "noctty-terminal-handoff-proxy.dll";
const iid_terminal_handoff1_text = "{59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}";
const iid_terminal_handoff2_text = "{AA6B364F-4A50-4176-9002-0AE755E7B5EF}";
const iid_terminal_handoff3_text = "{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}";
pub const CLSID_NOCTTY_TERMINAL = GUID.parse(clsid_text);
pub const CLSID_NOCTTY_TERMINAL_PROXY = GUID.parse(proxy_clsid_text);
pub const IID_ITerminalHandoff1 = GUID.parse(iid_terminal_handoff1_text);
pub const IID_ITerminalHandoff2 = GUID.parse(iid_terminal_handoff2_text);
pub const IID_ITerminalHandoff3 = GUID.parse(iid_terminal_handoff3_text);
const IID_IClassFactory = GUID.parse("{00000001-0000-0000-C000-000000000046}");

const CLSCTX_LOCAL_SERVER: DWORD = 0x4;
const REGCLS_MULTIPLEUSE: DWORD = 1;
const CLASS_E_NOAGGREGATION: HRESULT = @bitCast(@as(u32, 0x80040110));
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
const E_ACCESSDENIED: HRESULT = @bitCast(@as(u32, 0x80070005));

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_QUERY_VALUE: DWORD = 0x0001;
const KEY_SET_VALUE: DWORD = 0x0002;
const KEY_CREATE_SUB_KEY: DWORD = 0x0004;
const KEY_READ: DWORD = 0x20019;
const KEY_WRITE: DWORD = 0x20006;
const REG_OPTION_NON_VOLATILE: DWORD = 0;
const REG_SZ: DWORD = 1;
const REG_BINARY: DWORD = 3;
const REG_DWORD: DWORD = 4;
const ERROR_SUCCESS: LSTATUS = 0;
const ERROR_FILE_NOT_FOUND: LSTATUS = 2;
const ERROR_PATH_NOT_FOUND: LSTATUS = 3;
const ERROR_MORE_DATA: LSTATUS = 234;

const class_key_utf8 = "Software\\Classes\\CLSID\\" ++ clsid_text;
const local_server_key_utf8 = class_key_utf8 ++ "\\LocalServer32";
const proxy_class_key_utf8 = "Software\\Classes\\CLSID\\" ++ proxy_clsid_text;
const proxy_inproc_server_key_utf8 = proxy_class_key_utf8 ++ "\\InprocServer32";
const saved_state_key_utf8 = class_key_utf8 ++ "\\noctty.default-terminal";
const startup_key_utf8 = "Console\\%%Startup";
const InterfaceProxyRegistration = struct {
    key_utf8: []const u8,
    saved_key_utf8: []const u8,
};
const interface_proxy_registrations = [_]InterfaceProxyRegistration{
    .{
        .key_utf8 = "Software\\Classes\\Interface\\" ++ iid_terminal_handoff1_text ++ "\\ProxyStubClsid32",
        .saved_key_utf8 = saved_state_key_utf8 ++ "\\Interface\\" ++ iid_terminal_handoff1_text,
    },
    .{
        .key_utf8 = "Software\\Classes\\Interface\\" ++ iid_terminal_handoff2_text ++ "\\ProxyStubClsid32",
        .saved_key_utf8 = saved_state_key_utf8 ++ "\\Interface\\" ++ iid_terminal_handoff2_text,
    },
    .{
        .key_utf8 = "Software\\Classes\\Interface\\" ++ iid_terminal_handoff3_text ++ "\\ProxyStubClsid32",
        .saved_key_utf8 = saved_state_key_utf8 ++ "\\Interface\\" ++ iid_terminal_handoff3_text,
    },
};
const delegation_console_name = "DelegationConsole";
const delegation_terminal_name = "DelegationTerminal";
const inbox_console_sentinel = "{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}";
const null_guid = "{00000000-0000-0000-0000-000000000000}";

extern "ole32" fn CoRegisterClassObject(
    rclsid: *const GUID,
    object: *com.IUnknown,
    cls_context: DWORD,
    flags: DWORD,
    cookie: *DWORD,
) callconv(.winapi) HRESULT;
extern "ole32" fn CoRevokeClassObject(cookie: DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoImpersonateClient() callconv(.winapi) HRESULT;
extern "ole32" fn CoRevertToSelf() callconv(.winapi) HRESULT;

extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    Reserved: DWORD,
    lpClass: LPCWSTR,
    dwOptions: DWORD,
    samDesired: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    ulOptions: DWORD,
    samDesired: DWORD,
    phkResult: *HKEY,
) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: LPCWSTR,
    lpReserved: ?*DWORD,
    lpType: ?*DWORD,
    lpData: ?[*]u8,
    lpcbData: ?*DWORD,
) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: LPCWSTR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: ?[*]const u8,
    cbData: DWORD,
) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegDeleteValueW(hKey: HKEY, lpValueName: LPCWSTR) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegDeleteTreeW(hKey: HKEY, lpSubKey: [*:0]const u16) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) LSTATUS;

extern "advapi32" fn OpenProcessToken(
    ProcessHandle: HANDLE,
    DesiredAccess: DWORD,
    TokenHandle: *HANDLE,
) callconv(.winapi) BOOL;
extern "advapi32" fn RevertToSelf() callconv(.winapi) BOOL;
extern "advapi32" fn OpenThreadToken(
    ThreadHandle: HANDLE,
    DesiredAccess: DWORD,
    OpenAsSelf: BOOL,
    TokenHandle: *HANDLE,
) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(
    TokenHandle: HANDLE,
    TokenInformationClass: i32,
    TokenInformation: *anyopaque,
    TokenInformationLength: DWORD,
    ReturnLength: *DWORD,
) callconv(.winapi) BOOL;
extern "advapi32" fn GetSidSubAuthorityCount(Sid: *anyopaque) callconv(.winapi) *u8;
extern "advapi32" fn GetSidSubAuthority(Sid: *anyopaque, SubAuthority: DWORD) callconv(.winapi) *DWORD;

pub const TERMINAL_STARTUP_INFO = extern struct {
    pszTitle: com.BSTR,
    pszIconPath: com.BSTR,
    iconIndex: i32,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
};

pub const ITerminalHandoff3 = extern struct {
    vtbl: *const ITerminalHandoff3Vtbl,
};

pub const ITerminalHandoff3Vtbl = extern struct {
    QueryInterface: *const fn (*ITerminalHandoff3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ITerminalHandoff3) callconv(.winapi) u32,
    Release: *const fn (*ITerminalHandoff3) callconv(.winapi) u32,
    EstablishPtyHandoff: *const fn (
        *ITerminalHandoff3,
        *?HANDLE,
        *?HANDLE,
        ?HANDLE,
        ?HANDLE,
        ?HANDLE,
        ?HANDLE,
        ?*const TERMINAL_STARTUP_INFO,
    ) callconv(.winapi) HRESULT,
};

const IClassFactory = extern struct {
    vtbl: *const IClassFactoryVtbl,
};

const IClassFactoryVtbl = extern struct {
    QueryInterface: *const fn (*IClassFactory, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IClassFactory) callconv(.winapi) u32,
    Release: *const fn (*IClassFactory) callconv(.winapi) u32,
    CreateInstance: *const fn (*IClassFactory, ?*com.IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    LockServer: *const fn (*IClassFactory, BOOL) callconv(.winapi) HRESULT,
};

comptime {
    if (@sizeOf(TERMINAL_STARTUP_INFO) != 56 or @alignOf(TERMINAL_STARTUP_INFO) != 8)
        @compileError("TERMINAL_STARTUP_INFO ABI mismatch");
    const startup_offsets = .{
        .{ "pszTitle", 0 },         .{ "pszIconPath", 8 },    .{ "iconIndex", 16 },
        .{ "dwX", 20 },             .{ "dwY", 24 },           .{ "dwXSize", 28 },
        .{ "dwYSize", 32 },         .{ "dwXCountChars", 36 }, .{ "dwYCountChars", 40 },
        .{ "dwFillAttribute", 44 }, .{ "dwFlags", 48 },       .{ "wShowWindow", 52 },
    };
    for (startup_offsets) |expected| {
        if (@offsetOf(TERMINAL_STARTUP_INFO, expected[0]) != expected[1])
            @compileError("TERMINAL_STARTUP_INFO field offset mismatch");
    }
    if (@sizeOf(ITerminalHandoff3Vtbl) != 4 * @sizeOf(*anyopaque))
        @compileError("ITerminalHandoff3 vtable slot mismatch");
    if (@offsetOf(ITerminalHandoff3Vtbl, "QueryInterface") != 0 or
        @offsetOf(ITerminalHandoff3Vtbl, "AddRef") != @sizeOf(*anyopaque) or
        @offsetOf(ITerminalHandoff3Vtbl, "Release") != 2 * @sizeOf(*anyopaque) or
        @offsetOf(ITerminalHandoff3Vtbl, "EstablishPtyHandoff") != 3 * @sizeOf(*anyopaque))
        @compileError("ITerminalHandoff3 vtable order mismatch");
}

pub const PendingSession = struct {
    alloc: Allocator,
    adopted: ?ptypkg.AdoptedSession,
    title: []u8,

    pub fn takeAdopted(self: *PendingSession) ptypkg.AdoptedSession {
        const result = self.adopted.?;
        self.adopted = null;
        return result;
    }

    pub fn deinit(self: *PendingSession) void {
        if (self.adopted) |*session| {
            session.pty.deinit();
            _ = windows.CloseHandle(session.client_process);
        }
        self.alloc.free(self.title);
        self.* = undefined;
    }
};

pub const QueueSessionFn = *const fn (ctx: *anyopaque, pending: *PendingSession) bool;

/// Identifier handed to the UI thread in place of a `PendingSession` pointer.
///
/// It travels in an `LPARAM`, so it is sized to the platform word. Zero is
/// never issued: a message carrying no identifier and a message carrying an
/// identifier we never handed out are the same thing, and both are dropped.
pub const PendingId = usize;

/// Process-owned table of handoff sessions waiting for the UI thread.
///
/// The wake-up for a completed handoff is a thread message, and any process on
/// this desktop at our integrity level can post that message with an `LPARAM`
/// of its choosing. Carrying the `PendingSession` pointer in the message would
/// mean dereferencing, deinitializing and freeing an address the sender picked,
/// so the message carries only an identifier that is resolved here. An
/// identifier we never issued - or issued and already consumed - resolves to
/// null, and the message is dropped without touching any session.
pub const PendingQueue = struct {
    mutex: std.Thread.Mutex = .{},
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        id: PendingId,
        session: *PendingSession,
    };

    /// Takes ownership of `session` and returns the identifier that stands for
    /// it. The identifier is never zero.
    pub fn insert(
        self: *PendingQueue,
        alloc: Allocator,
        session: *PendingSession,
    ) Allocator.Error!PendingId {
        self.mutex.lock();
        defer self.mutex.unlock();
        var source: CryptoCapabilitySource = .{};
        const id = self.nextCapabilityWithSource(&source);
        try self.entries.append(alloc, .{ .id = id, .session = session });
        return id;
    }

    const CryptoCapabilitySource = struct {
        fn next(_: *@This()) PendingId {
            return std.crypto.random.int(PendingId);
        }
    };

    fn nextCapabilityWithSource(self: *PendingQueue, source: anytype) PendingId {
        while (true) {
            const candidate = source.next();
            if (candidate == 0) continue;
            for (self.entries.items) |entry| {
                if (entry.id == candidate) break;
            } else return candidate;
        }
    }

    /// Resolves `id` and hands ownership back to the caller, or returns null
    /// when the identifier was never issued or has already been consumed.
    pub fn take(self: *PendingQueue, id: PendingId) ?*PendingSession {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items, 0..) |entry, index| {
            if (entry.id != id) continue;
            _ = self.entries.orderedRemove(index);
            return entry.session;
        }
        return null;
    }

    pub fn isEmpty(self: *PendingQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len == 0;
    }

    /// Destroys every session that never reached the UI thread.
    pub fn drain(self: *PendingQueue, alloc: Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            entry.session.deinit();
            alloc.destroy(entry.session);
        }
        self.entries.clearAndFree(alloc);
    }
};

pub const Server = struct {
    alloc: Allocator,
    queue_ctx: *anyopaque,
    queue_session: QueueSessionFn,
    factory: ClassFactory,
    factory_initialized: bool = false,
    factory_registration_refs: std.atomic.Value(u32) = .init(0),
    cookie: ?DWORD = null,
    lock_count: std.atomic.Value(u32) = .init(0),
    live_objects: std.atomic.Value(u32) = .init(0),
    pending: PendingQueue = .{},

    pub fn init(alloc: Allocator, queue_ctx: *anyopaque, queue_session: QueueSessionFn) Server {
        return .{
            .alloc = alloc,
            .queue_ctx = queue_ctx,
            .queue_session = queue_session,
            .factory = undefined,
        };
    }

    pub fn register(self: *Server) !void {
        if (!self.factory_initialized) {
            self.factory = ClassFactory.init(self);
            self.factory_initialized = true;
        }
        const refs_before = self.factory.refcount.load(.acquire);
        var cookie: DWORD = 0;
        const hr = CoRegisterClassObject(
            &CLSID_NOCTTY_TERMINAL,
            @ptrCast(&self.factory.base),
            CLSCTX_LOCAL_SERVER,
            REGCLS_MULTIPLEUSE,
            &cookie,
        );
        if (hr < 0) {
            log.err("CoRegisterClassObject failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return error.ComRegistrationFailed;
        }
        self.cookie = cookie;
        const refs_after = self.factory.refcount.load(.acquire);
        self.factory_registration_refs.store(refs_after - refs_before, .release);
    }

    pub fn revoke(self: *Server) bool {
        const cookie = self.cookie orelse return true;
        const hr = CoRevokeClassObject(cookie);
        if (!self.finishRevoke(hr)) {
            log.warn("CoRevokeClassObject failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return false;
        }
        return true;
    }

    fn finishRevoke(self: *Server, hr: HRESULT) bool {
        if (hr < 0) return false;
        self.cookie = null;
        self.factory_registration_refs.store(0, .release);
        return true;
    }

    /// Takes ownership of `session` and returns the identifier the UI thread
    /// will use to claim it back.
    pub fn queuePending(self: *Server, session: *PendingSession) Allocator.Error!PendingId {
        return self.pending.insert(self.alloc, session);
    }

    /// Claims the session an identifier stands for, or null when the
    /// identifier is not one we issued and still owe.
    pub fn takePending(self: *Server, id: PendingId) ?*PendingSession {
        return self.pending.take(id);
    }

    /// Destroys every queued session. Only safe once the class object is
    /// revoked and the UI thread has stopped consuming handoffs.
    pub fn drainPending(self: *Server) void {
        self.pending.drain(self.alloc);
    }

    /// True while the class object must stay registered.
    ///
    /// Four things keep it alive. A client can hold an IClassFactory pointer
    /// without calling LockServer; references beyond the server's own and
    /// COM's registration references keep that pointer valid. A client can
    /// also hold it through
    /// IClassFactory::LockServer, which is where an activation slower than the
    /// idle timeout sits between CoGetClassObject and CreateInstance. A client
    /// can also hold an ITerminalHandoff3 instance it created: LockServer is
    /// optional in the COM contract, so a client may legally create the object
    /// and call EstablishPtyHandoff later without ever locking, and an
    /// out-of-process server must outlive the objects it handed out. Finally a
    /// completed handoff may still be waiting for the UI thread to adopt it.
    pub fn isBusy(self: *Server) bool {
        const external_factory_ref = if (self.factory_initialized)
            self.factory.refcount.load(.acquire) >
                1 + self.factory_registration_refs.load(.acquire)
        else
            false;
        return external_factory_ref or
            self.lock_count.load(.acquire) > 0 or
            self.live_objects.load(.acquire) > 0 or
            !self.pending.isEmpty();
    }
};

const ClassFactory = struct {
    base: IClassFactory,
    refcount: std.atomic.Value(u32),
    server: *Server,

    const vtbl: IClassFactoryVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .CreateInstance = CreateInstance,
        .LockServer = LockServer,
    };

    fn init(server: *Server) ClassFactory {
        return .{
            .base = .{ .vtbl = &vtbl },
            .refcount = .init(1),
            .server = server,
        };
    }

    fn fromBase(base: *IClassFactory) *ClassFactory {
        return @fieldParentPtr("base", base);
    }

    fn QueryInterface(base: *IClassFactory, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (!iidEqual(iid, &com.IID_IUnknown) and !iidEqual(iid, &IID_IClassFactory)) return com.E_NOINTERFACE;
        out.* = base;
        _ = AddRef(base);
        return com.S_OK;
    }

    fn AddRef(base: *IClassFactory) callconv(.winapi) u32 {
        return fromBase(base).refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Release(base: *IClassFactory) callconv(.winapi) u32 {
        const self = fromBase(base);
        const previous = self.refcount.fetchSub(1, .acq_rel);
        return previous - 1;
    }

    fn CreateInstance(
        base: *IClassFactory,
        outer: ?*com.IUnknown,
        iid: *const GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        out.* = null;
        if (outer != null) return CLASS_E_NOAGGREGATION;
        const self = fromBase(base);
        const handoff = TerminalHandoff.create(self.server) catch return com.E_OUTOFMEMORY;
        const hr = handoff.base.vtbl.QueryInterface(&handoff.base, iid, out);
        _ = handoff.base.vtbl.Release(&handoff.base);
        return hr;
    }

    fn LockServer(base: *IClassFactory, lock: BOOL) callconv(.winapi) HRESULT {
        const count = &fromBase(base).server.lock_count;
        if (lock != 0) {
            _ = count.fetchAdd(1, .monotonic);
        } else if (count.load(.acquire) > 0) {
            _ = count.fetchSub(1, .acq_rel);
        }
        return com.S_OK;
    }
};

const TerminalHandoff = struct {
    base: ITerminalHandoff3,
    refcount: std.atomic.Value(u32),
    server: *Server,

    var legacy_qi_logged = std.atomic.Value(bool).init(false);
    var integrity_failure_logged = std.atomic.Value(bool).init(false);

    const vtbl: ITerminalHandoff3Vtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .EstablishPtyHandoff = EstablishPtyHandoff,
    };

    fn create(server: *Server) Allocator.Error!*TerminalHandoff {
        const self = try server.alloc.create(TerminalHandoff);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = .init(1),
            .server = server,
        };
        // Counted from creation to final release so the idle path cannot kill
        // the process underneath a client that holds this object but has not
        // called LockServer.
        _ = server.live_objects.fetchAdd(1, .monotonic);
        return self;
    }

    fn fromBase(base: *ITerminalHandoff3) *TerminalHandoff {
        return @fieldParentPtr("base", base);
    }

    fn QueryInterface(base: *ITerminalHandoff3, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or iidEqual(iid, &IID_ITerminalHandoff3)) {
            out.* = base;
            _ = AddRef(base);
            return com.S_OK;
        }
        if (iidEqual(iid, &IID_ITerminalHandoff1) or iidEqual(iid, &IID_ITerminalHandoff2)) {
            if (!legacy_qi_logged.swap(true, .acq_rel)) {
                log.warn("ITerminalHandoff v1/v2 rejected; noctty requires ITerminalHandoff3 from Windows Terminal/OpenConsole 1.24 or newer", .{});
            }
        }
        return com.E_NOINTERFACE;
    }

    fn AddRef(base: *ITerminalHandoff3) callconv(.winapi) u32 {
        return fromBase(base).refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Release(base: *ITerminalHandoff3) callconv(.winapi) u32 {
        const self = fromBase(base);
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            const server = self.server;
            self.server.alloc.destroy(self);
            _ = server.live_objects.fetchSub(1, .acq_rel);
            return 0;
        }
        return previous - 1;
    }

    fn EstablishPtyHandoff(
        base: *ITerminalHandoff3,
        input: *?HANDLE,
        output: *?HANDLE,
        signal_in: ?HANDLE,
        reference_in: ?HANDLE,
        server_process_in: ?HANDLE,
        client_process_in: ?HANDLE,
        startup_info: ?*const TERMINAL_STARTUP_INFO,
    ) callconv(.winapi) HRESULT {
        input.* = null;
        output.* = null;
        const self = fromBase(base);
        const signal = signal_in orelse return self.fail("missing_signal_handle", com.E_INVALIDARG);
        const reference = reference_in orelse return self.fail("missing_reference_handle", com.E_INVALIDARG);
        const server_process = server_process_in orelse return self.fail("missing_server_process_handle", com.E_INVALIDARG);
        const client_process = client_process_in orelse return self.fail("missing_client_process_handle", com.E_INVALIDARG);

        const authorization = authorizeHandoffIntegrity();
        if (authorization != .accepted) {
            const reason = handoffIntegrityFailureReason(authorization);
            if (!integrity_failure_logged.swap(true, .acq_rel)) {
                log.err("terminal handoff rejected: {s}; Windows will fall back to a console window", .{reason});
            }
            return self.fail(reason, E_ACCESSDENIED);
        }

        const signal_copy = duplicateLocalHandle(signal) catch return self.fail("duplicate_signal_handle_failed", E_FAIL);
        var signal_owned = true;
        defer {
            if (signal_owned) _ = windows.CloseHandle(signal_copy);
        }
        const reference_copy = duplicateLocalHandle(reference) catch return self.fail("duplicate_reference_handle_failed", E_FAIL);
        var reference_owned = true;
        defer {
            if (reference_owned) _ = windows.CloseHandle(reference_copy);
        }
        const server_copy = duplicateLocalHandle(server_process) catch return self.fail("duplicate_server_process_handle_failed", E_FAIL);
        var server_owned = true;
        defer {
            if (server_owned) _ = windows.CloseHandle(server_copy);
        }
        const client_copy = duplicateLocalHandle(client_process) catch return self.fail("duplicate_client_process_handle_failed", E_FAIL);
        var client_owned = true;
        defer {
            if (client_owned) _ = windows.CloseHandle(client_copy);
        }

        var pty = ptypkg.Pty.openAdopted(.{}, signal_copy, server_copy, reference_copy) catch return self.fail("open_adopted_pty_failed", E_FAIL);
        signal_owned = false;
        server_owned = false;
        reference_owned = false;
        var pty_owned = true;
        defer if (pty_owned) pty.deinit();

        const title = cloneStartupTitle(self.server.alloc, startup_info) catch return self.fail("clone_startup_title_failed", com.E_OUTOFMEMORY);
        var title_owned = true;
        defer if (title_owned) self.server.alloc.free(title);
        const pending = self.server.alloc.create(PendingSession) catch return self.fail("allocate_pending_session_failed", com.E_OUTOFMEMORY);
        pending.* = .{
            .alloc = self.server.alloc,
            .adopted = .{ .pty = pty, .client_process = client_copy },
            .title = title,
        };
        title_owned = false;
        pty_owned = false;
        client_owned = false;

        const handles = pending.adopted.?.pty.handoffHandles() orelse {
            pending.deinit();
            self.server.alloc.destroy(pending);
            return self.fail("adopted_pty_handles_unavailable", E_FAIL);
        };
        // Returning S_OK hands both pipe ends to the RPC stub, which
        // duplicates them into the client and closes this process's originals.
        // Drop them from the Pty before the session becomes reachable from any
        // other thread: after `queue_session` the UI thread owns `pending`, and
        // a close from there would be a double close that aborts the process
        // (`std.os.windows.CloseHandle` asserts `NtClose` succeeded) before the
        // adopted session can become a window.
        pending.adopted.?.pty.releaseHandoffPipeCopies();

        if (!self.server.queue_session(self.server.queue_ctx, pending)) {
            // This call fails, so nothing is marshaled and the two released
            // ends are still ours to close.
            _ = windows.CloseHandle(handles.input);
            _ = windows.CloseHandle(handles.output);
            pending.deinit();
            self.server.alloc.destroy(pending);
            return self.fail("queue_pending_session_failed", E_FAIL);
        }

        input.* = handles.input;
        output.* = handles.output;
        appendHandoffMilestone(self.server.alloc, "handoff_accepted");
        return com.S_OK;
    }

    fn fail(self: *TerminalHandoff, reason: []const u8, hr: HRESULT) HRESULT {
        appendHandoffFailureTrace(self.server.alloc, reason, hr);
        return hr;
    }
};

fn iidEqual(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn duplicateLocalHandle(source: HANDLE) !HANDLE {
    var duplicate: HANDLE = undefined;
    const process = windows.GetCurrentProcess();
    if (windows.kernel32.DuplicateHandle(
        process,
        source,
        process,
        &duplicate,
        0,
        windows.FALSE,
        windows.DUPLICATE_SAME_ACCESS,
    ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());
    return duplicate;
}

fn cloneStartupTitle(alloc: Allocator, startup_info: ?*const TERMINAL_STARTUP_INFO) ![]u8 {
    const bstr = if (startup_info) |info| info.pszTitle else null;
    const title = bstr orelse return alloc.dupe(u8, "noctty");
    const len: usize = com.SysStringLen(title);
    if (len == 0) return alloc.dupe(u8, "noctty");
    return std.unicode.utf16LeToUtf8Alloc(alloc, title[0..len]);
}

const TOKEN_QUERY: DWORD = 0x0008;
const TOKEN_INTEGRITY_LEVEL: i32 = 25;
const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?*anyopaque,
    Attributes: DWORD,
};
const TOKEN_MANDATORY_LABEL = extern struct {
    Label: SID_AND_ATTRIBUTES,
};

fn tokenIntegrityRid(token: HANDLE) ?DWORD {
    var buffer: [256]u8 align(8) = undefined;
    var needed: DWORD = 0;
    if (GetTokenInformation(token, TOKEN_INTEGRITY_LEVEL, &buffer, buffer.len, &needed) == 0) return null;
    const label: *const TOKEN_MANDATORY_LABEL = @ptrCast(@alignCast(&buffer));
    const sid = label.Label.Sid orelse return null;
    const count = GetSidSubAuthorityCount(sid).*;
    if (count == 0) return null;
    return GetSidSubAuthority(sid, count - 1).*;
}

fn currentProcessIntegrityRid() ?DWORD {
    var token: HANDLE = undefined;
    if (OpenProcessToken(windows.GetCurrentProcess(), TOKEN_QUERY, &token) == 0) return null;
    defer _ = windows.CloseHandle(token);
    return tokenIntegrityRid(token);
}

const ComCallerIntegrity = union(enum) {
    rid: DWORD,
    com_impersonation_failed,
    com_caller_token_unavailable,
    com_caller_integrity_unavailable,
    com_revert_failed,
};

const Win32ComCallerIntegrityOps = struct {
    fn impersonate(_: *@This()) HRESULT {
        return CoImpersonateClient();
    }

    fn openThreadToken(_: *@This()) ?HANDLE {
        var token: HANDLE = undefined;
        if (OpenThreadToken(windows.GetCurrentThread(), TOKEN_QUERY, windows.TRUE, &token) == 0)
            return null;
        return token;
    }

    fn integrityRid(_: *@This(), token: HANDLE) ?DWORD {
        return tokenIntegrityRid(token);
    }

    fn closeToken(_: *@This(), token: HANDLE) void {
        _ = windows.CloseHandle(token);
    }

    fn revert(_: *@This()) HRESULT {
        return CoRevertToSelf();
    }

    /// Whether this thread still carries an impersonation token. A failure
    /// that is not ERROR_NO_TOKEN tells us nothing, so it counts as still
    /// impersonating: the recovery path is cheap and being wrong the other way
    /// is not survivable.
    fn isImpersonating(_: *@This()) bool {
        var token: HANDLE = undefined;
        if (OpenThreadToken(windows.GetCurrentThread(), TOKEN_QUERY, windows.TRUE, &token) != 0) {
            _ = windows.CloseHandle(token);
            return true;
        }
        return windows.kernel32.GetLastError() != .NO_TOKEN;
    }

    /// Drop the impersonation token without going through COM. CoRevertToSelf
    /// can fail for reasons of its own bookkeeping while the underlying thread
    /// token is still detachable.
    fn forceRevert(_: *@This()) bool {
        return RevertToSelf() != 0;
    }
};

const RevertRecovery = enum { recovered, leaked };

/// What became of the impersonation token after CoRevertToSelf failed.
///
/// The thread that runs EstablishPtyHandoff is the process message loop. It
/// goes on to create windows, read configuration, write session state and
/// spawn shells, so leaving it impersonating the COM caller is not a failed
/// handoff, it is every later operation running under someone else's token.
/// Confirm the token is really still attached, try once to drop it directly,
/// and confirm again.
fn recoverFromFailedRevertWithOps(ops: anytype) RevertRecovery {
    if (!ops.isImpersonating()) return .recovered;
    if (!ops.forceRevert()) return .leaked;
    return if (ops.isImpersonating()) .leaked else .recovered;
}

fn comCallerIntegrityRidWithOps(ops: anytype) ComCallerIntegrity {
    if (ops.impersonate() < 0) return .com_impersonation_failed;

    const result: ComCallerIntegrity = result: {
        const token = ops.openThreadToken() orelse break :result .com_caller_token_unavailable;
        defer ops.closeToken(token);
        break :result if (ops.integrityRid(token)) |rid|
            .{ .rid = rid }
        else
            .com_caller_integrity_unavailable;
    };

    if (ops.revert() < 0) return .com_revert_failed;
    return result;
}

fn comCallerIntegrityRid() ComCallerIntegrity {
    var ops: Win32ComCallerIntegrityOps = .{};
    const result = comCallerIntegrityRidWithOps(&ops);
    switch (result) {
        .com_revert_failed => if (recoverFromFailedRevertWithOps(&ops) == .leaked) {
            // Refusing this one handoff is not enough: the message loop would
            // keep running as the caller. Taking the process down loses the
            // adopted windows it hosts, and that is the cheaper loss - Windows
            // falls back to a console window for the pending launch, while
            // continuing would act on the user's registry, files and child
            // processes under an identity we did not choose and cannot drop.
            log.err("CoRevertToSelf failed and the handoff thread is still impersonating the COM caller", .{});
            @panic("terminal handoff thread could not stop impersonating its COM caller");
        },
        else => {},
    }
    return result;
}

const HandoffIntegrityAuthorization = enum {
    accepted,
    current_process_unavailable,
    com_impersonation_failed,
    com_caller_token_unavailable,
    com_caller_integrity_unavailable,
    com_revert_failed,
    mismatch,
};

fn decideHandoffIntegrityAuthorization(
    current_process_rid: ?DWORD,
    com_caller: ComCallerIntegrity,
) HandoffIntegrityAuthorization {
    const current = current_process_rid orelse return .current_process_unavailable;
    return switch (com_caller) {
        .rid => |caller| if (caller == current) .accepted else .mismatch,
        .com_impersonation_failed => .com_impersonation_failed,
        .com_caller_token_unavailable => .com_caller_token_unavailable,
        .com_caller_integrity_unavailable => .com_caller_integrity_unavailable,
        .com_revert_failed => .com_revert_failed,
    };
}

fn authorizeHandoffIntegrity() HandoffIntegrityAuthorization {
    return decideHandoffIntegrityAuthorization(
        currentProcessIntegrityRid(),
        comCallerIntegrityRid(),
    );
}

fn handoffIntegrityFailureReason(authorization: HandoffIntegrityAuthorization) []const u8 {
    return switch (authorization) {
        .accepted => unreachable,
        .current_process_unavailable => "current_process_integrity_unavailable",
        .com_impersonation_failed => "com_caller_impersonation_failed",
        .com_caller_token_unavailable => "com_caller_token_unavailable",
        .com_caller_integrity_unavailable => "com_caller_integrity_unavailable",
        .com_revert_failed => "com_caller_revert_failed",
        .mismatch => "com_caller_integrity_mismatch",
    };
}

const handoff_trace_max_bytes: u64 = 1024 * 1024;

fn appendHandoffFailureTrace(alloc: Allocator, reason: []const u8, hr: HRESULT) void {
    var line_buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buffer,
        "reason={s} hr=0x{x:0>8}",
        .{ reason, @as(u32, @bitCast(hr)) },
    ) catch return;
    appendHandoffTrace(alloc, line);
}

/// Record a milestone the handoff reached. Only failures used to be traced,
/// which cannot distinguish "never activated" from "activated, adopted, then
/// lost on the way to a window" - the shape of the defect this trace was added
/// to find. Milestones make that difference visible without a debugger.
pub fn appendHandoffMilestone(alloc: Allocator, event: []const u8) void {
    var line_buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "event={s}", .{event}) catch return;
    appendHandoffTrace(alloc, line);
}

fn appendHandoffTrace(alloc: Allocator, line: []const u8) void {
    if (!std.process.hasNonEmptyEnvVarConstant("NOCTTY_HANDOFF_TRACE")) return;

    const local_app_data = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return;
    defer alloc.free(local_app_data);
    const dir_path = std.fs.path.join(alloc, &.{ local_app_data, "noctty" }) catch return;
    defer alloc.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch return;
    const log_path = std.fs.path.join(alloc, &.{ dir_path, "handoff.log" }) catch return;
    defer alloc.free(log_path);

    appendHandoffTraceAtPath(log_path, line) catch return;
}

fn appendHandoffTraceAtPath(log_path: []const u8, line: []const u8) !void {
    const file = try std.fs.createFileAbsolute(log_path, .{ .truncate = false });
    defer file.close();
    const current_size = try file.getEndPos();
    if (current_size + line.len + 2 > handoff_trace_max_bytes) {
        try file.setEndPos(0);
        try file.seekTo(0);
    } else {
        try file.seekTo(current_size);
    }
    try file.writeAll(line);
    try file.writeAll("\r\n");
    try file.sync();
}

pub fn isEmbeddingArgs(argv: []const []const u8) bool {
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-e")) return false;
        if (std.ascii.eqlIgnoreCase(arg, "-Embedding")) return true;
    }
    return false;
}

pub fn isEmbeddingProcess(alloc: Allocator) bool {
    const argv = std.process.argsAlloc(alloc) catch return false;
    defer std.process.argsFree(alloc, argv);
    return isEmbeddingArgs(argv);
}

const RawRegistryValue = struct {
    value_type: DWORD,
    data: []u8,

    fn deinit(self: RawRegistryValue, alloc: Allocator) void {
        alloc.free(self.data);
    }
};

const SavedRegistryValue = struct {
    value: ?RawRegistryValue,

    fn deinit(self: SavedRegistryValue, alloc: Allocator) void {
        if (self.value) |value| value.deinit(alloc);
    }
};

const RegistryValueSnapshot = struct {
    key: []const u8,
    name: ?[]const u8,
    value: ?RawRegistryValue,

    fn deinit(self: RegistryValueSnapshot, alloc: Allocator) void {
        if (self.value) |value| value.deinit(alloc);
    }

    fn capture(
        alloc: Allocator,
        key: []const u8,
        name: ?[]const u8,
    ) (Allocator.Error || RegistrationError)!RegistryValueSnapshot {
        return .{ .key = key, .name = name, .value = try queryValueAlloc(alloc, key, name) };
    }

    fn restore(self: RegistryValueSnapshot, alloc: Allocator) (Allocator.Error || RegistrationError)!void {
        if (self.value) |value| {
            try writeRegistryRaw(alloc, self.key, self.name, value);
        } else {
            try deleteRegistryValue(alloc, self.key, self.name);
        }
    }
};

const UnregistrationSnapshot = struct {
    selection: RegistryValueSnapshot,
    registration: RegistrationRefreshSnapshot,

    fn capture(alloc: Allocator) (Allocator.Error || RegistrationError)!UnregistrationSnapshot {
        const selection = try RegistryValueSnapshot.capture(alloc, startup_key_utf8, delegation_terminal_name);
        errdefer selection.deinit(alloc);
        return .{ .selection = selection, .registration = try RegistrationRefreshSnapshot.capture(alloc) };
    }

    fn deinit(self: *UnregistrationSnapshot, alloc: Allocator) void {
        self.selection.deinit(alloc);
        self.registration.deinit(alloc);
    }
};

const RegistrationRefreshSnapshot = struct {
    values: std.ArrayListUnmanaged(RegistryValueSnapshot) = .empty,
    had_owned_state: bool = false,

    fn capture(alloc: Allocator) (Allocator.Error || RegistrationError)!RegistrationRefreshSnapshot {
        var self: RegistrationRefreshSnapshot = .{};
        errdefer self.deinit(alloc);

        try self.captureValue(alloc, class_key_utf8, null, true);
        try self.captureValue(alloc, local_server_key_utf8, null, true);
        try self.captureValue(alloc, proxy_class_key_utf8, null, true);
        try self.captureValue(alloc, proxy_inproc_server_key_utf8, null, true);
        try self.captureValue(alloc, proxy_inproc_server_key_utf8, "ThreadingModel", true);
        try self.captureValue(alloc, saved_state_key_utf8, "Present", true);
        try self.captureValue(alloc, saved_state_key_utf8, "Type", true);
        try self.captureValue(alloc, saved_state_key_utf8, "Data", true);
        for (interface_proxy_registrations) |registration| {
            try self.captureValue(alloc, registration.key_utf8, null, false);
            try self.captureValue(alloc, registration.saved_key_utf8, "Present", true);
            try self.captureValue(alloc, registration.saved_key_utf8, "Type", true);
            try self.captureValue(alloc, registration.saved_key_utf8, "Data", true);
        }
        return self;
    }

    fn captureValue(
        self: *RegistrationRefreshSnapshot,
        alloc: Allocator,
        key: []const u8,
        name: ?[]const u8,
        owned_state: bool,
    ) (Allocator.Error || RegistrationError)!void {
        const snapshot = try RegistryValueSnapshot.capture(alloc, key, name);
        errdefer snapshot.deinit(alloc);
        if (owned_state and snapshot.value != null) self.had_owned_state = true;
        try self.values.append(alloc, snapshot);
    }

    fn restore(self: RegistrationRefreshSnapshot, alloc: Allocator) (Allocator.Error || RegistrationError)!void {
        var index = self.values.items.len;
        while (index > 0) {
            index -= 1;
            const snapshot = self.values.items[index];
            try snapshot.restore(alloc);
        }
    }

    fn findValue(
        self: RegistrationRefreshSnapshot,
        key: []const u8,
        name: ?[]const u8,
    ) ?RegistryValueSnapshot {
        for (self.values.items) |snapshot| {
            if (!std.mem.eql(u8, snapshot.key, key)) continue;
            if (snapshot.name == null or name == null) {
                if (snapshot.name == null and name == null) return snapshot;
                continue;
            }
            if (std.mem.eql(u8, snapshot.name.?, name.?)) return snapshot;
        }
        return null;
    }

    fn deinit(self: *RegistrationRefreshSnapshot, alloc: Allocator) void {
        for (self.values.items) |snapshot| snapshot.deinit(alloc);
        self.values.deinit(alloc);
    }
};

pub const RegisterResult = struct {
    selection_changed: bool,
};

pub const UnregisterResult = struct {
    selection_restored: bool,
    newer_selection_preserved: bool,
    class_removed: bool,
};

pub const RegistrationError = error{
    CompatibleConsoleHandoffMissing,
    InvalidUtf8,
    InvalidConsoleHandoff,
    MissingRestoreState,
    MissingProxyRestoreState,
    ProxyDllMissing,
    RegistryFailure,
    InvalidRegistryValue,
};

const ConsoleHalf = enum { compatible, missing, null_guid, inbox, invalid };

fn classifyConsoleHalf(value: ?[]const u8) ConsoleHalf {
    const text = value orelse return .missing;
    if (std.ascii.eqlIgnoreCase(text, null_guid)) return .null_guid;
    if (std.ascii.eqlIgnoreCase(text, inbox_console_sentinel)) return .inbox;
    if (text.len != 38 or text[0] != '{' or text[37] != '}') return .invalid;
    // std's parseNoBraces asserts the dash positions rather than returning an
    // error, so a same-length braced value without dashes would panic (and is
    // UB in ReleaseFast) instead of landing in the .invalid arm below. Check
    // the shape ourselves before handing the text over.
    for ([_]usize{ 9, 14, 19, 24 }) |dash_index| {
        if (text[dash_index] != '-') return .invalid;
    }
    _ = GUID.parseNoBraces(text[1..37]) catch return .invalid;
    return .compatible;
}

fn requireCompatibleConsoleHalf(value: ?[]const u8) RegistrationError!void {
    switch (classifyConsoleHalf(value)) {
        .compatible => {},
        .missing, .null_guid, .inbox => return error.CompatibleConsoleHandoffMissing,
        .invalid => return error.InvalidConsoleHandoff,
    }
}

fn consoleHalfTextAlloc(alloc: Allocator) (Allocator.Error || RegistrationError)!?[]u8 {
    const raw = try queryValueAlloc(alloc, startup_key_utf8, delegation_console_name);
    defer if (raw) |value| value.deinit(alloc);
    return if (raw) |value| try registrySzToUtf8Alloc(alloc, value) else null;
}

const SelectionCommit = enum { already_selected, commit };

const RegistrationRollback = enum { cleanup_new, restore_snapshot };

fn decideRegistrationRollback(terminal_is_ours: bool, had_owned_state: bool) RegistrationRollback {
    return if (terminal_is_ours or had_owned_state) .restore_snapshot else .cleanup_new;
}

/// Whether the terminal half may be written, given what the console half looks
/// like right now.
///
/// DelegationConsole and DelegationTerminal are two independent values and the
/// user can change their default terminal in Settings while we are part way
/// through writing our own keys. Registration checks the console half early to
/// fail fast, but the check that matters is this one, immediately before the
/// commit: a stale check would let us publish a pair whose console half is the
/// inbox console or a stranger's CLSID and still report success. Rejecting
/// here prevents changing the selected terminal; the registration wrapper
/// rolls back any class or proxy values written before this final check.
fn decideSelectionCommit(
    terminal_is_ours: bool,
    console_half: ?[]const u8,
) RegistrationError!SelectionCommit {
    try requireCompatibleConsoleHalf(console_half);
    if (terminal_is_ours) return .already_selected;
    return .commit;
}

pub fn nocttyExePathForLauncher(alloc: Allocator, launcher_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(launcher_path) orelse return error.InvalidExecutablePath;
    const candidate = try std.fs.path.join(alloc, &.{ dir, "noctty.exe" });
    defer alloc.free(candidate);
    return std.fs.path.resolve(alloc, &.{candidate});
}

pub fn currentNocttyExePath(alloc: Allocator) ![]u8 {
    const launcher = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(launcher);
    return nocttyExePathForLauncher(alloc, launcher);
}

pub fn localServerCommand(alloc: Allocator, exe_path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(exe_path)) return error.InvalidExecutablePath;
    return std.fmt.allocPrint(alloc, "\"{s}\"", .{exe_path});
}

pub fn proxyDllPathForExe(alloc: Allocator, exe_path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(exe_path)) return error.InvalidExecutablePath;
    const dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
    const candidate = try std.fs.path.join(alloc, &.{ dir, proxy_filename });
    defer alloc.free(candidate);
    return std.fs.path.resolve(alloc, &.{candidate});
}

pub fn registerDefaultTerminal(alloc: Allocator, exe_path: []const u8) (Allocator.Error || RegistrationError || error{InvalidExecutablePath})!RegisterResult {
    const proxy_path = try proxyDllPathForExe(alloc, exe_path);
    defer alloc.free(proxy_path);
    const proxy_file = std.fs.openFileAbsolute(proxy_path, .{}) catch return error.ProxyDllMissing;
    proxy_file.close();

    const console_text = try consoleHalfTextAlloc(alloc);
    defer if (console_text) |value| alloc.free(value);
    try requireCompatibleConsoleHalf(console_text);

    const terminal_raw = try queryValueAlloc(alloc, startup_key_utf8, delegation_terminal_name);
    defer if (terminal_raw) |value| value.deinit(alloc);
    const terminal_is_noctty = if (terminal_raw) |value| try registryValueEqualsGuidAlloc(alloc, value, clsid_text) else false;
    if (terminal_is_noctty) {
        const saved = try loadSavedRegistryValue(alloc, saved_state_key_utf8);
        saved.deinit(alloc);
    }

    const command = try localServerCommand(alloc, exe_path);
    defer alloc.free(command);
    var refresh_snapshot = try RegistrationRefreshSnapshot.capture(alloc);
    defer refresh_snapshot.deinit(alloc);
    const rollback = decideRegistrationRollback(terminal_is_noctty, refresh_snapshot.had_owned_state);
    // Ordering is load-bearing: every shared Interface value is snapshotted
    // before anything is written, and the user's terminal selection is
    // switched last, so a failure part way through leaves the previous
    // terminal selected with its restore state intact.
    const selection_changed = writeRegistration(alloc, command, proxy_path) catch |err| {
        // The terminal selection is the commit point. If its final console
        // check or any earlier registry mutation fails, restore every shared
        // proxy mapping and either restore the prior dormant registration or
        // remove class keys created by this attempt.
        switch (rollback) {
            .restore_snapshot => refresh_snapshot.restore(alloc) catch |rollback_err| {
                log.err("default-terminal refresh rollback failed err={}", .{rollback_err});
                return rollback_err;
            },
            .cleanup_new => _ = unregisterDefaultTerminal(alloc) catch |rollback_err| {
                log.err("default-terminal registration rollback failed err={}", .{rollback_err});
                return rollback_err;
            },
        }
        return err;
    };
    return .{ .selection_changed = selection_changed };
}

fn writeRegistration(
    alloc: Allocator,
    command: []const u8,
    proxy_path: []const u8,
) (Allocator.Error || RegistrationError)!bool {
    for (interface_proxy_registrations) |registration| {
        try savePreviousInterfaceProxy(alloc, registration);
    }
    try writeRegistrySz(alloc, class_key_utf8, null, "noctty Terminal Handoff");
    try writeRegistrySz(alloc, local_server_key_utf8, null, command);
    try writeRegistrySz(alloc, proxy_class_key_utf8, null, "noctty Terminal Handoff Proxy/Stub");
    try writeRegistrySz(alloc, proxy_inproc_server_key_utf8, null, proxy_path);
    try writeRegistrySz(alloc, proxy_inproc_server_key_utf8, "ThreadingModel", "Both");
    for (interface_proxy_registrations) |registration| {
        try writeRegistrySz(alloc, registration.key_utf8, null, proxy_clsid_text);
    }
    return selectTerminal(alloc);
}

const UnregistrationJournal = struct {
    selection_restored: bool = false,
    interfaces_restored: [interface_proxy_registrations.len]bool = @splat(false),
    proxy_class_delete_attempted: bool = false,
    proxy_class_removed: bool = false,
    main_class_delete_attempted: bool = false,
};

const UnregisterTransaction = struct {
    alloc: Allocator,
    snapshot: *const UnregistrationSnapshot,
    terminal_restore: ?SavedRegistryValue,
    interface_restores: *const [interface_proxy_registrations.len]?SavedRegistryValue,
    journal: UnregistrationJournal = .{},

    fn mutate(self: *@This()) (Allocator.Error || RegistrationError)!UnregisterResult {
        // Mirror of the registration order: hand the selection back first,
        // then the shared Interface values, and only then delete noctty's own
        // classes, so no window of time has the selection pointing at a
        // removed class.
        const selection_result = try restoreSelectionIfOwned(self.alloc, self.terminal_restore);
        self.journal.selection_restored = selection_result.restored;
        for (interface_proxy_registrations, 0..) |registration, index| {
            self.journal.interfaces_restored[index] = try restoreInterfaceProxyIfOwned(
                self.alloc,
                registration,
                self.interface_restores[index],
            );
        }
        self.journal.proxy_class_delete_attempted = true;
        self.journal.proxy_class_removed = try deleteRegistryTree(self.alloc, proxy_class_key_utf8);
        self.journal.main_class_delete_attempted = true;
        const class_removed = (try deleteRegistryTree(self.alloc, class_key_utf8)) or self.journal.proxy_class_removed;
        return .{
            .selection_restored = selection_result.restored,
            .newer_selection_preserved = selection_result.newer_selection_preserved,
            .class_removed = class_removed,
        };
    }

    fn rollback(self: *@This()) (Allocator.Error || RegistrationError)!void {
        var first_error: ?(Allocator.Error || RegistrationError) = null;

        // Rebuild owned class values before reconnecting the shared Interface
        // and terminal selection values. A failed RegDeleteTreeW may leave a
        // partially deleted tree, so restore the known schema when its owner
        // value is absent or still matches this transaction's baseline.
        if (self.journal.main_class_delete_attempted) {
            self.restoreOwnedClassBestEffort(
                class_key_utf8,
                local_server_key_utf8,
                &first_error,
            );
        }
        if (self.journal.proxy_class_delete_attempted) {
            self.restoreOwnedClassBestEffort(
                proxy_class_key_utf8,
                proxy_inproc_server_key_utf8,
                &first_error,
            );
        }

        // Undo shared values in reverse order and only if they still equal the
        // value this unregistration wrote. This preserves a newer Settings or
        // portable-install choice made while rollback is in progress.
        var index = interface_proxy_registrations.len;
        while (index > 0) {
            index -= 1;
            if (!self.journal.interfaces_restored[index]) continue;
            const expected = self.interface_restores[index] orelse unreachable;
            const snapshot = self.snapshot.registration.findValue(
                interface_proxy_registrations[index].key_utf8,
                null,
            ) orelse unreachable;
            restoreSnapshotIfCurrentMatches(
                self.alloc,
                snapshot,
                expected.value,
            ) catch |err| rememberRollbackError(&first_error, err);
        }
        if (self.journal.selection_restored) {
            const expected = self.terminal_restore orelse unreachable;
            restoreSnapshotIfCurrentMatches(
                self.alloc,
                self.snapshot.selection,
                expected.value,
            ) catch |err| rememberRollbackError(&first_error, err);
        }

        if (first_error) |err| return err;
    }

    fn restoreOwnedClassBestEffort(
        self: *@This(),
        class_key: []const u8,
        owner_value_key: []const u8,
        first_error: *?(Allocator.Error || RegistrationError),
    ) void {
        const owner_snapshot = self.snapshot.registration.findValue(owner_value_key, null) orelse unreachable;
        const current_owner = queryValueAlloc(self.alloc, owner_value_key, null) catch |err| {
            rememberRollbackError(first_error, err);
            return;
        };
        defer if (current_owner) |value| value.deinit(self.alloc);
        if (current_owner != null and !rawRegistryValuesEqual(current_owner, owner_snapshot.value)) return;

        var index = self.snapshot.registration.values.items.len;
        while (index > 0) {
            index -= 1;
            const snapshot = self.snapshot.registration.values.items[index];
            if (!std.mem.eql(u8, snapshot.key, class_key) and
                !(std.mem.startsWith(u8, snapshot.key, class_key) and
                    snapshot.key.len > class_key.len and
                    snapshot.key[class_key.len] == '\\')) continue;
            snapshot.restore(self.alloc) catch |err| rememberRollbackError(first_error, err);
        }
    }
};

fn rememberRollbackError(
    first_error: *?(Allocator.Error || RegistrationError),
    err: (Allocator.Error || RegistrationError),
) void {
    if (first_error.* == null) first_error.* = err;
}

fn rawRegistryValuesEqual(lhs: ?RawRegistryValue, rhs: ?RawRegistryValue) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return lhs.?.value_type == rhs.?.value_type and std.mem.eql(u8, lhs.?.data, rhs.?.data);
}

fn restoreSnapshotIfCurrentMatches(
    alloc: Allocator,
    snapshot: RegistryValueSnapshot,
    expected: ?RawRegistryValue,
) (Allocator.Error || RegistrationError)!void {
    const current = try queryValueAlloc(alloc, snapshot.key, snapshot.name);
    defer if (current) |value| value.deinit(alloc);
    if (!rawRegistryValuesEqual(current, expected)) return;
    try snapshot.restore(alloc);
}

fn runUnregisterMutationWithRollback(
    context: anytype,
    comptime mutate: anytype,
    comptime rollback: anytype,
) (Allocator.Error || RegistrationError)!UnregisterResult {
    return mutate(context) catch |err| {
        rollback(context) catch |rollback_err| {
            log.err("default-terminal unregistration rollback failed err={}", .{rollback_err});
            return rollback_err;
        };
        return err;
    };
}

pub fn unregisterDefaultTerminal(alloc: Allocator) (Allocator.Error || RegistrationError)!UnregisterResult {
    const terminal_raw = try queryValueAlloc(alloc, startup_key_utf8, delegation_terminal_name);
    defer if (terminal_raw) |value| value.deinit(alloc);
    const terminal_is_noctty = if (terminal_raw) |value| try registryValueEqualsGuidAlloc(alloc, value, clsid_text) else false;

    var terminal_restore: ?SavedRegistryValue = null;
    if (terminal_is_noctty) terminal_restore = try loadSavedRegistryValue(alloc, saved_state_key_utf8);
    defer if (terminal_restore) |value| value.deinit(alloc);

    var interface_restores: [interface_proxy_registrations.len]?SavedRegistryValue = @splat(null);
    defer for (&interface_restores) |*restore| {
        if (restore.*) |value| value.deinit(alloc);
    };
    for (interface_proxy_registrations, 0..) |registration, index| {
        const current = try queryValueAlloc(alloc, registration.key_utf8, null);
        defer if (current) |value| value.deinit(alloc);
        if (try interfaceProxyIsOursAlloc(alloc, current)) {
            interface_restores[index] = loadSavedRegistryValue(alloc, registration.saved_key_utf8) catch |err| switch (err) {
                error.MissingRestoreState => return error.MissingProxyRestoreState,
                else => return err,
            };
        }
    }

    // Capture immediately before the first mutation. Failed unregisters use
    // this snapshot plus the mutation journal to restore the exact baseline.
    var snapshot = try UnregistrationSnapshot.capture(alloc);
    defer snapshot.deinit(alloc);
    var transaction: UnregisterTransaction = .{
        .alloc = alloc,
        .snapshot = &snapshot,
        .terminal_restore = terminal_restore,
        .interface_restores = &interface_restores,
    };
    return runUnregisterMutationWithRollback(
        &transaction,
        UnregisterTransaction.mutate,
        UnregisterTransaction.rollback,
    );
}

fn savePreviousTerminal(alloc: Allocator, previous: ?RawRegistryValue) (Allocator.Error || RegistrationError)!void {
    try saveRegistryValue(alloc, saved_state_key_utf8, previous);
}

fn selectTerminal(alloc: Allocator) (Allocator.Error || RegistrationError)!bool {
    const current = try queryValueAlloc(alloc, startup_key_utf8, delegation_terminal_name);
    defer if (current) |value| value.deinit(alloc);
    const is_ours = if (current) |value| try registryValueEqualsGuidAlloc(alloc, value, clsid_text) else false;

    // Re-read the console half here rather than trusting the check
    // registration made before it started writing.
    const console_text = try consoleHalfTextAlloc(alloc);
    defer if (console_text) |value| alloc.free(value);
    switch (try decideSelectionCommit(is_ours, console_text)) {
        .already_selected => {
            const saved = try loadSavedRegistryValue(alloc, saved_state_key_utf8);
            saved.deinit(alloc);
            return false;
        },
        .commit => {},
    }

    try savePreviousTerminal(alloc, current);
    try writeRegistrySz(alloc, startup_key_utf8, delegation_terminal_name, clsid_text);
    return true;
}

fn savePreviousInterfaceProxy(alloc: Allocator, registration: InterfaceProxyRegistration) (Allocator.Error || RegistrationError)!void {
    const current = try queryValueAlloc(alloc, registration.key_utf8, null);
    defer if (current) |value| value.deinit(alloc);
    if (try interfaceProxyIsOursAlloc(alloc, current)) {
        const saved = loadSavedRegistryValue(alloc, registration.saved_key_utf8) catch |err| switch (err) {
            error.MissingRestoreState => return error.MissingProxyRestoreState,
            else => return err,
        };
        saved.deinit(alloc);
        return;
    }
    try saveRegistryValue(alloc, registration.saved_key_utf8, current);
}

fn saveRegistryValue(alloc: Allocator, saved_key: []const u8, previous: ?RawRegistryValue) (Allocator.Error || RegistrationError)!void {
    try deleteRegistryValue(alloc, saved_key, "Present");
    if (previous) |value| {
        try writeRegistryDword(alloc, saved_key, "Type", value.value_type);
        try writeRegistryBytes(alloc, saved_key, "Data", REG_BINARY, value.data);
        try writeRegistryDword(alloc, saved_key, "Present", 1);
    } else {
        try deleteRegistryValue(alloc, saved_key, "Type");
        try deleteRegistryValue(alloc, saved_key, "Data");
        try writeRegistryDword(alloc, saved_key, "Present", 0);
    }
}

fn loadSavedRegistryValue(alloc: Allocator, saved_key: []const u8) (Allocator.Error || RegistrationError)!SavedRegistryValue {
    const present_raw = (try queryValueAlloc(alloc, saved_key, "Present")) orelse
        return error.MissingRestoreState;
    defer present_raw.deinit(alloc);
    const was_present = try registryDword(present_raw);
    if (was_present == 0) return .{ .value = null };
    if (was_present != 1) return error.InvalidRegistryValue;

    const type_raw = (try queryValueAlloc(alloc, saved_key, "Type")) orelse
        return error.MissingRestoreState;
    defer type_raw.deinit(alloc);
    var data_raw = (try queryValueAlloc(alloc, saved_key, "Data")) orelse
        return error.MissingRestoreState;
    errdefer data_raw.deinit(alloc);
    const value_type = try registryDword(type_raw);
    return .{ .value = .{ .value_type = value_type, .data = data_raw.data } };
}

fn restoreSavedRegistryValue(
    alloc: Allocator,
    key_utf8: []const u8,
    name_utf8: ?[]const u8,
    saved: SavedRegistryValue,
) (Allocator.Error || RegistrationError)!void {
    if (saved.value) |value| {
        try writeRegistryRaw(alloc, key_utf8, name_utf8, value);
    } else {
        try deleteRegistryValue(alloc, key_utf8, name_utf8);
    }
}

const SelectionRestoreResult = struct {
    restored: bool,
    newer_selection_preserved: bool,
};

fn restoreSelectionIfOwned(
    alloc: Allocator,
    saved: ?SavedRegistryValue,
) (Allocator.Error || RegistrationError)!SelectionRestoreResult {
    const current = try queryValueAlloc(alloc, startup_key_utf8, delegation_terminal_name);
    defer if (current) |value| value.deinit(alloc);
    const is_ours = if (current) |value| try registryValueEqualsGuidAlloc(alloc, value, clsid_text) else false;
    if (!is_ours) return .{ .restored = false, .newer_selection_preserved = current != null };
    try restoreSavedRegistryValue(
        alloc,
        startup_key_utf8,
        delegation_terminal_name,
        saved orelse return error.MissingRestoreState,
    );
    return .{ .restored = true, .newer_selection_preserved = false };
}

fn restoreInterfaceProxyIfOwned(
    alloc: Allocator,
    registration: InterfaceProxyRegistration,
    saved: ?SavedRegistryValue,
) (Allocator.Error || RegistrationError)!bool {
    const current = try queryValueAlloc(alloc, registration.key_utf8, null);
    defer if (current) |value| value.deinit(alloc);
    if (!try interfaceProxyIsOursAlloc(alloc, current)) return false;
    try restoreSavedRegistryValue(
        alloc,
        registration.key_utf8,
        null,
        saved orelse return error.MissingProxyRestoreState,
    );
    return true;
}

fn shouldRestoreInterfaceProxyText(current: ?[]const u8) bool {
    const text_value = current orelse return false;
    return std.ascii.eqlIgnoreCase(text_value, proxy_clsid_text);
}

fn interfaceProxyIsOursAlloc(alloc: Allocator, current: ?RawRegistryValue) Allocator.Error!bool {
    const value = current orelse return false;
    const text_value = registrySzToUtf8Alloc(alloc, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer alloc.free(text_value);
    return shouldRestoreInterfaceProxyText(text_value);
}

fn registryDword(value: RawRegistryValue) RegistrationError!DWORD {
    if (value.value_type != REG_DWORD or value.data.len != @sizeOf(DWORD)) return error.InvalidRegistryValue;
    return std.mem.readInt(DWORD, value.data[0..4], .little);
}

fn registryValueEqualsGuidAlloc(alloc: Allocator, value: RawRegistryValue, expected: []const u8) (Allocator.Error || RegistrationError)!bool {
    const text = try registrySzToUtf8Alloc(alloc, value);
    defer alloc.free(text);
    return std.ascii.eqlIgnoreCase(text, expected);
}

fn registrySzToUtf8Alloc(alloc: Allocator, value: RawRegistryValue) (Allocator.Error || RegistrationError)![]u8 {
    if (value.value_type != REG_SZ or value.data.len < 2 or value.data.len % 2 != 0) return error.InvalidRegistryValue;
    const wide = try alloc.alloc(u16, value.data.len / @sizeOf(u16));
    defer alloc.free(wide);
    for (wide, 0..) |*unit, i| {
        unit.* = std.mem.readInt(u16, value.data[i * 2 ..][0..2], .little);
    }
    if (wide[wide.len - 1] != 0) return error.InvalidRegistryValue;
    return std.unicode.utf16LeToUtf8Alloc(alloc, wide[0 .. wide.len - 1]) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRegistryValue,
    };
}

fn queryValueAlloc(alloc: Allocator, key_utf8: []const u8, name_utf8: ?[]const u8) (Allocator.Error || RegistrationError)!?RawRegistryValue {
    const key_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_utf8);
    defer alloc.free(key_w);
    var key: HKEY = undefined;
    const open_rc = RegOpenKeyExW(HKEY_CURRENT_USER, key_w.ptr, 0, KEY_READ, &key);
    if (open_rc == ERROR_FILE_NOT_FOUND or open_rc == ERROR_PATH_NOT_FOUND) return null;
    if (open_rc != ERROR_SUCCESS) return registryFailure("RegOpenKeyExW", open_rc);
    defer _ = RegCloseKey(key);

    const name_w = if (name_utf8) |name| try std.unicode.utf8ToUtf16LeAllocZ(alloc, name) else null;
    defer if (name_w) |name| alloc.free(name);
    var value_type: DWORD = 0;
    var size: DWORD = 0;
    const size_rc = RegQueryValueExW(key, if (name_w) |name| name.ptr else null, null, &value_type, null, &size);
    if (size_rc == ERROR_FILE_NOT_FOUND) return null;
    if (size_rc != ERROR_SUCCESS) return registryFailure("RegQueryValueExW(size)", size_rc);

    var data = try alloc.alloc(u8, size);
    errdefer alloc.free(data);
    var actual_size = size;
    const read_rc = RegQueryValueExW(key, if (name_w) |name| name.ptr else null, null, &value_type, if (data.len == 0) null else data.ptr, &actual_size);
    if (read_rc == ERROR_MORE_DATA) return error.RegistryFailure;
    if (read_rc != ERROR_SUCCESS) return registryFailure("RegQueryValueExW(data)", read_rc);
    if (actual_size != data.len) {
        const exact = try alloc.dupe(u8, data[0..actual_size]);
        alloc.free(data);
        data = exact;
    }
    return .{ .value_type = value_type, .data = data };
}

fn writeRegistrySz(alloc: Allocator, key: []const u8, name: ?[]const u8, value: []const u8) (Allocator.Error || RegistrationError)!void {
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value);
    defer alloc.free(value_w);
    const with_nul = value_w.ptr[0 .. value_w.len + 1];
    try writeRegistryBytes(alloc, key, name, REG_SZ, std.mem.sliceAsBytes(with_nul));
}

fn writeRegistryDword(alloc: Allocator, key: []const u8, name: []const u8, value: DWORD) (Allocator.Error || RegistrationError)!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(DWORD, &bytes, value, .little);
    try writeRegistryBytes(alloc, key, name, REG_DWORD, &bytes);
}

fn writeRegistryRaw(alloc: Allocator, key: []const u8, name: ?[]const u8, value: RawRegistryValue) (Allocator.Error || RegistrationError)!void {
    try writeRegistryBytes(alloc, key, name, value.value_type, value.data);
}

fn writeRegistryBytes(
    alloc: Allocator,
    key_utf8: []const u8,
    name_utf8: ?[]const u8,
    value_type: DWORD,
    data: []const u8,
) (Allocator.Error || RegistrationError)!void {
    const key_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_utf8);
    defer alloc.free(key_w);
    const name_w = if (name_utf8) |name| try std.unicode.utf8ToUtf16LeAllocZ(alloc, name) else null;
    defer if (name_w) |name| alloc.free(name);

    var key: HKEY = undefined;
    const open_rc = RegCreateKeyExW(
        HKEY_CURRENT_USER,
        key_w.ptr,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE | KEY_QUERY_VALUE | KEY_CREATE_SUB_KEY | KEY_SET_VALUE,
        null,
        &key,
        null,
    );
    if (open_rc != ERROR_SUCCESS) return registryFailure("RegCreateKeyExW", open_rc);
    defer _ = RegCloseKey(key);
    const set_rc = RegSetValueExW(
        key,
        if (name_w) |name| name.ptr else null,
        0,
        value_type,
        if (data.len == 0) null else data.ptr,
        @intCast(data.len),
    );
    if (set_rc != ERROR_SUCCESS) return registryFailure("RegSetValueExW", set_rc);
}

fn deleteRegistryValue(alloc: Allocator, key_utf8: []const u8, name_utf8: ?[]const u8) (Allocator.Error || RegistrationError)!void {
    const key_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_utf8);
    defer alloc.free(key_w);
    const name_w = if (name_utf8) |name| try std.unicode.utf8ToUtf16LeAllocZ(alloc, name) else null;
    defer if (name_w) |name| alloc.free(name);
    var key: HKEY = undefined;
    const open_rc = RegOpenKeyExW(HKEY_CURRENT_USER, key_w.ptr, 0, KEY_SET_VALUE, &key);
    if (open_rc == ERROR_FILE_NOT_FOUND or open_rc == ERROR_PATH_NOT_FOUND) return;
    if (open_rc != ERROR_SUCCESS) return registryFailure("RegOpenKeyExW(delete value)", open_rc);
    defer _ = RegCloseKey(key);
    const rc = RegDeleteValueW(key, if (name_w) |name| name.ptr else null);
    if (rc != ERROR_SUCCESS and rc != ERROR_FILE_NOT_FOUND) return registryFailure("RegDeleteValueW", rc);
}

fn deleteRegistryTree(alloc: Allocator, key_utf8: []const u8) (Allocator.Error || RegistrationError)!bool {
    const existing = try queryKeyExists(alloc, key_utf8);
    if (!existing) return false;
    const key_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_utf8);
    defer alloc.free(key_w);
    const rc = RegDeleteTreeW(HKEY_CURRENT_USER, key_w.ptr);
    if (rc != ERROR_SUCCESS and rc != ERROR_FILE_NOT_FOUND and rc != ERROR_PATH_NOT_FOUND)
        return registryFailure("RegDeleteTreeW", rc);
    return rc == ERROR_SUCCESS;
}

fn queryKeyExists(alloc: Allocator, key_utf8: []const u8) (Allocator.Error || RegistrationError)!bool {
    const key_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_utf8);
    defer alloc.free(key_w);
    var key: HKEY = undefined;
    const rc = RegOpenKeyExW(HKEY_CURRENT_USER, key_w.ptr, 0, KEY_READ, &key);
    if (rc == ERROR_FILE_NOT_FOUND or rc == ERROR_PATH_NOT_FOUND) return false;
    if (rc != ERROR_SUCCESS) return registryFailure("RegOpenKeyExW(exists)", rc);
    _ = RegCloseKey(key);
    return true;
}

fn registryFailure(comptime operation: []const u8, rc: LSTATUS) RegistrationError {
    log.err("{s} failed rc={d}", .{ operation, rc });
    return error.RegistryFailure;
}

test "handoff permanent CLSID and IIDs have pinned bytes" {
    try std.testing.expectEqualSlices(u8, &.{ 0x6f, 0x8c, 0x36, 0x33, 0x28, 0xd3, 0x0c, 0x41, 0xb2, 0x25, 0x26, 0xdc, 0x9f, 0x12, 0xc7, 0x28 }, std.mem.asBytes(&CLSID_NOCTTY_TERMINAL));
    try std.testing.expectEqualSlices(u8, &.{ 0x24, 0x98, 0x34, 0x1d, 0xfb, 0x21, 0xc7, 0x46, 0xac, 0xf3, 0x74, 0x6e, 0xdc, 0x99, 0x1d, 0x52 }, std.mem.asBytes(&CLSID_NOCTTY_TERMINAL_PROXY));
    try std.testing.expectEqualSlices(u8, &.{ 0x90, 0xda, 0x23, 0x6f, 0xc5, 0x15, 0x03, 0x42, 0x9d, 0xb0, 0x64, 0xe7, 0x3f, 0x1b, 0x1b, 0x00 }, std.mem.asBytes(&IID_ITerminalHandoff3));
    try std.testing.expectEqualSlices(u8, &.{ 0xce, 0x5c, 0xd5, 0x59, 0x8a, 0xfc, 0xb4, 0x48, 0xac, 0xe8, 0x0a, 0x92, 0x86, 0xc6, 0x55, 0x7f }, std.mem.asBytes(&IID_ITerminalHandoff1));
    try std.testing.expectEqualSlices(u8, &.{ 0x4f, 0x36, 0x6b, 0xaa, 0x50, 0x4a, 0x76, 0x41, 0x90, 0x02, 0x0a, 0xe7, 0x55, 0xe7, 0xb5, 0xef }, std.mem.asBytes(&IID_ITerminalHandoff2));
}

test "handoff startup info and vtable ABI" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(TERMINAL_STARTUP_INFO));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(TERMINAL_STARTUP_INFO));
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(*anyopaque)), @sizeOf(ITerminalHandoff3Vtbl));
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(*anyopaque)), @offsetOf(ITerminalHandoff3Vtbl, "EstablishPtyHandoff"));
}

test "handoff QueryInterface AddRef Release and legacy rejection" {
    const Queue = struct {
        fn call(_: *anyopaque, _: *PendingSession) bool {
            return false;
        }
    };
    var context: u8 = 0;
    var server = Server.init(std.testing.allocator, &context, Queue.call);
    const handoff = try TerminalHandoff.create(&server);
    try std.testing.expectEqual(@as(u32, 2), handoff.base.vtbl.AddRef(&handoff.base));
    try std.testing.expectEqual(@as(u32, 1), handoff.base.vtbl.Release(&handoff.base));
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, handoff.base.vtbl.QueryInterface(&handoff.base, &IID_ITerminalHandoff3, &out));
    try std.testing.expect(out != null);
    try std.testing.expectEqual(@as(u32, 1), handoff.base.vtbl.Release(&handoff.base));
    try std.testing.expectEqual(com.E_NOINTERFACE, handoff.base.vtbl.QueryInterface(&handoff.base, &IID_ITerminalHandoff1, &out));
    try std.testing.expect(out == null);
    try std.testing.expectEqual(com.E_NOINTERFACE, handoff.base.vtbl.QueryInterface(&handoff.base, &IID_ITerminalHandoff2, &out));
    try std.testing.expectEqual(@as(u32, 0), handoff.base.vtbl.Release(&handoff.base));
}

test "handoff authorization uses COM caller integrity and distinguishes unavailable evidence" {
    try std.testing.expectEqual(
        HandoffIntegrityAuthorization.accepted,
        decideHandoffIntegrityAuthorization(0x2000, .{ .rid = 0x2000 }),
    );
    try std.testing.expectEqual(
        HandoffIntegrityAuthorization.mismatch,
        decideHandoffIntegrityAuthorization(0x2000, .{ .rid = 0x3000 }),
    );
    try std.testing.expectEqual(
        HandoffIntegrityAuthorization.current_process_unavailable,
        decideHandoffIntegrityAuthorization(null, .{ .rid = 0x2000 }),
    );
    try std.testing.expectEqual(
        HandoffIntegrityAuthorization.com_caller_token_unavailable,
        decideHandoffIntegrityAuthorization(0x2000, .com_caller_token_unavailable),
    );
}

test "handoff COM caller inspection always reverts successful impersonation" {
    const State = struct {
        token_available: bool = true,
        integrity_available: bool = true,
        revert_hr: HRESULT = com.S_OK,
        revert_count: usize = 0,
        close_count: usize = 0,

        fn impersonate(_: *@This()) HRESULT {
            return com.S_OK;
        }

        fn openThreadToken(self: *@This()) ?HANDLE {
            return if (self.token_available) @ptrFromInt(1) else null;
        }

        fn integrityRid(self: *@This(), _: HANDLE) ?DWORD {
            return if (self.integrity_available) 0x2000 else null;
        }

        fn closeToken(self: *@This(), _: HANDLE) void {
            self.close_count += 1;
        }

        fn revert(self: *@This()) HRESULT {
            self.revert_count += 1;
            return self.revert_hr;
        }
    };

    var success: State = .{};
    try std.testing.expectEqual(
        ComCallerIntegrity{ .rid = 0x2000 },
        comCallerIntegrityRidWithOps(&success),
    );
    try std.testing.expectEqual(@as(usize, 1), success.revert_count);
    try std.testing.expectEqual(@as(usize, 1), success.close_count);

    var no_token: State = .{ .token_available = false };
    try std.testing.expectEqual(
        ComCallerIntegrity.com_caller_token_unavailable,
        comCallerIntegrityRidWithOps(&no_token),
    );
    try std.testing.expectEqual(@as(usize, 1), no_token.revert_count);
    try std.testing.expectEqual(@as(usize, 0), no_token.close_count);

    var no_integrity: State = .{ .integrity_available = false };
    try std.testing.expectEqual(
        ComCallerIntegrity.com_caller_integrity_unavailable,
        comCallerIntegrityRidWithOps(&no_integrity),
    );
    try std.testing.expectEqual(@as(usize, 1), no_integrity.revert_count);
    try std.testing.expectEqual(@as(usize, 1), no_integrity.close_count);

    var revert_failed: State = .{ .revert_hr = E_FAIL };
    try std.testing.expectEqual(
        ComCallerIntegrity.com_revert_failed,
        comCallerIntegrityRidWithOps(&revert_failed),
    );
    try std.testing.expectEqual(@as(usize, 1), revert_failed.revert_count);
    try std.testing.expectEqual(@as(usize, 1), revert_failed.close_count);
}

test "handoff revert failure is only survivable once the token is gone" {
    const State = struct {
        impersonating: bool,
        force_ok: bool,
        force_count: usize = 0,

        fn isImpersonating(self: *@This()) bool {
            return self.impersonating;
        }

        fn forceRevert(self: *@This()) bool {
            self.force_count += 1;
            if (self.force_ok) self.impersonating = false;
            return self.force_ok;
        }
    };

    // CoRevertToSelf reported failure but the thread carries no token, so
    // nothing runs as the caller and the handoff can just fail.
    var already_clean: State = .{ .impersonating = false, .force_ok = true };
    try std.testing.expectEqual(RevertRecovery.recovered, recoverFromFailedRevertWithOps(&already_clean));
    try std.testing.expectEqual(@as(usize, 0), already_clean.force_count);

    var force_works: State = .{ .impersonating = true, .force_ok = true };
    try std.testing.expectEqual(RevertRecovery.recovered, recoverFromFailedRevertWithOps(&force_works));
    try std.testing.expectEqual(@as(usize, 1), force_works.force_count);

    // The token outlived both attempts. The caller must not keep serving.
    var stuck: State = .{ .impersonating = true, .force_ok = false };
    try std.testing.expectEqual(RevertRecovery.leaked, recoverFromFailedRevertWithOps(&stuck));
    try std.testing.expectEqual(@as(usize, 1), stuck.force_count);
}

test "handoff pending queue resolves only identifiers it issued" {
    const Queue = struct {
        fn call(_: *anyopaque, _: *PendingSession) bool {
            return false;
        }
    };
    var context: u8 = 0;
    const alloc = std.testing.allocator;
    var server = Server.init(alloc, &context, Queue.call);
    defer server.drainPending();

    const session = try alloc.create(PendingSession);
    session.* = .{
        .alloc = alloc,
        .adopted = null,
        .title = try alloc.dupe(u8, "noctty"),
    };
    const id = try server.queuePending(session);
    try std.testing.expect(id != 0);
    try std.testing.expect(server.isBusy());

    const Source = struct {
        values: []const PendingId,
        index: usize = 0,

        fn next(self: *@This()) PendingId {
            defer self.index += 1;
            return self.values[self.index];
        }
    };
    const available: PendingId = if (id == 42) 43 else 42;
    const candidates = [_]PendingId{ 0, id, available };
    var source: Source = .{ .values = &candidates };
    try std.testing.expectEqual(
        available,
        server.pending.nextCapabilityWithSource(&source),
    );
    try std.testing.expectEqual(candidates.len, source.index);

    // A forged message carries an identifier we never handed out. It must be
    // dropped without disturbing the session that is genuinely waiting.
    try std.testing.expect(server.takePending(0) == null);
    try std.testing.expect(server.takePending(id +% 1) == null);
    try std.testing.expect(server.takePending(std.math.maxInt(PendingId)) == null);
    try std.testing.expect(server.isBusy());

    try std.testing.expectEqual(session, server.takePending(id).?);
    try std.testing.expect(!server.isBusy());

    // Replaying the real identifier must not hand the session out twice.
    try std.testing.expect(server.takePending(id) == null);
    session.deinit();
    alloc.destroy(session);
}

test "handoff server stays alive for objects that never called LockServer" {
    const Queue = struct {
        fn call(_: *anyopaque, _: *PendingSession) bool {
            return false;
        }
    };
    var context: u8 = 0;
    var server = Server.init(std.testing.allocator, &context, Queue.call);
    try std.testing.expect(!server.isBusy());

    const handoff = try TerminalHandoff.create(&server);
    // No LockServer call: the object alone has to keep the server alive.
    try std.testing.expectEqual(@as(u32, 0), server.lock_count.load(.acquire));
    try std.testing.expect(server.isBusy());

    var out: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, handoff.base.vtbl.QueryInterface(&handoff.base, &IID_ITerminalHandoff3, &out));
    try std.testing.expectEqual(@as(u32, 1), handoff.base.vtbl.Release(&handoff.base));
    try std.testing.expect(server.isBusy());

    try std.testing.expectEqual(@as(u32, 0), handoff.base.vtbl.Release(&handoff.base));
    try std.testing.expect(!server.isBusy());
}

test "handoff server stays alive for outstanding class factory references" {
    const Queue = struct {
        fn call(_: *anyopaque, _: *PendingSession) bool {
            return false;
        }
    };
    var context: u8 = 0;
    var server = Server.init(std.testing.allocator, &context, Queue.call);
    server.factory = ClassFactory.init(&server);
    server.factory_initialized = true;
    try std.testing.expect(!server.isBusy());

    // CoGetClassObject may hand this pointer to a client without the client
    // ever calling LockServer. That reference alone must block idle exit.
    try std.testing.expectEqual(@as(u32, 2), server.factory.base.vtbl.AddRef(&server.factory.base));
    try std.testing.expect(server.isBusy());
    try std.testing.expectEqual(@as(u32, 1), server.factory.base.vtbl.Release(&server.factory.base));
    try std.testing.expect(!server.isBusy());
}

test "handoff server retains registration state when revocation fails" {
    const Queue = struct {
        fn call(_: *anyopaque, _: *PendingSession) bool {
            return false;
        }
    };
    var context: u8 = 0;
    var server = Server.init(std.testing.allocator, &context, Queue.call);
    server.cookie = 42;
    server.factory_registration_refs.store(1, .release);

    try std.testing.expect(!server.finishRevoke(E_FAIL));
    try std.testing.expectEqual(@as(?DWORD, 42), server.cookie);
    try std.testing.expectEqual(@as(u32, 1), server.factory_registration_refs.load(.acquire));

    try std.testing.expect(server.finishRevoke(com.S_OK));
    try std.testing.expectEqual(@as(?DWORD, null), server.cookie);
    try std.testing.expectEqual(@as(u32, 0), server.factory_registration_refs.load(.acquire));
}

test "handoff selection commit rechecks the console half before writing" {
    // Registration already passed its own console check; by the time the
    // selection is written the value can be something else entirely.
    try std.testing.expectEqual(
        SelectionCommit.commit,
        try decideSelectionCommit(false, "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"),
    );
    try std.testing.expectError(
        error.CompatibleConsoleHandoffMissing,
        decideSelectionCommit(false, inbox_console_sentinel),
    );
    try std.testing.expectError(
        error.CompatibleConsoleHandoffMissing,
        decideSelectionCommit(false, null),
    );
    try std.testing.expectError(
        error.InvalidConsoleHandoff,
        decideSelectionCommit(false, "not-a-guid"),
    );
    // A refresh still rewrites class and proxy values, so it must not report
    // success after Settings changes the console half underneath it.
    try std.testing.expectError(
        error.CompatibleConsoleHandoffMissing,
        decideSelectionCommit(true, inbox_console_sentinel),
    );
    try std.testing.expectEqual(
        SelectionCommit.already_selected,
        try decideSelectionCommit(true, "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"),
    );
}

test "handoff registration rollback preserves dormant owned state" {
    try std.testing.expectEqual(
        RegistrationRollback.cleanup_new,
        decideRegistrationRollback(false, false),
    );
    try std.testing.expectEqual(
        RegistrationRollback.restore_snapshot,
        decideRegistrationRollback(true, false),
    );
    // A different terminal may be selected while this installation's class
    // and saved restore values remain registered. A failed refresh must put
    // those dormant values back instead of uninstalling them.
    try std.testing.expectEqual(
        RegistrationRollback.restore_snapshot,
        decideRegistrationRollback(false, true),
    );
}

test "handoff unregistration rolls back partial mutations without clobbering newer state" {
    const State = struct {
        current: u8 = 1,
        preserve_newer: bool = false,
        rollback_count: usize = 0,

        fn mutate(self: *@This()) (Allocator.Error || RegistrationError)!UnregisterResult {
            self.current = 2;
            // Model a concurrent Settings change between the failed mutation
            // and rollback. The inverse must preserve that newer value.
            if (self.preserve_newer) self.current = 3;
            return error.RegistryFailure;
        }

        fn rollback(self: *@This()) (Allocator.Error || RegistrationError)!void {
            self.rollback_count += 1;
            if (self.current == 2) self.current = 1;
        }
    };

    var partial: State = .{};
    try std.testing.expectError(
        error.RegistryFailure,
        runUnregisterMutationWithRollback(&partial, State.mutate, State.rollback),
    );
    try std.testing.expectEqual(@as(u8, 1), partial.current);
    try std.testing.expectEqual(@as(usize, 1), partial.rollback_count);

    var concurrent: State = .{ .preserve_newer = true };
    try std.testing.expectError(
        error.RegistryFailure,
        runUnregisterMutationWithRollback(&concurrent, State.mutate, State.rollback),
    );
    try std.testing.expectEqual(@as(u8, 3), concurrent.current);
    try std.testing.expectEqual(@as(usize, 1), concurrent.rollback_count);

    var expected_data = [_]u8{ 1, 2, 3 };
    var newer_data = [_]u8{ 1, 2, 4 };
    const expected: RawRegistryValue = .{ .value_type = REG_BINARY, .data = &expected_data };
    const same: RawRegistryValue = .{ .value_type = REG_BINARY, .data = &expected_data };
    const newer: RawRegistryValue = .{ .value_type = REG_BINARY, .data = &newer_data };
    try std.testing.expect(rawRegistryValuesEqual(expected, same));
    try std.testing.expect(!rawRegistryValuesEqual(expected, newer));
    try std.testing.expect(!rawRegistryValuesEqual(expected, null));
}

test "handoff failure trace stays within its byte budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file = try tmp.dir.createFile("handoff.log", .{});
        defer file.close();
        try file.setEndPos(handoff_trace_max_bytes);
    }
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "handoff.log");
    defer std.testing.allocator.free(path);

    try appendHandoffTraceAtPath(path, "reason=bounded_failure hr=0x80004005");
    const stat = try std.fs.cwd().statFile(path);
    try std.testing.expect(stat.size <= handoff_trace_max_bytes);
    const contents = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        path,
        handoff_trace_max_bytes,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "reason=bounded_failure") != null);
}

test "handoff embedding argument detection respects command boundary" {
    try std.testing.expect(isEmbeddingArgs(&.{ "noctty.exe", "-Embedding" }));
    try std.testing.expect(isEmbeddingArgs(&.{ "noctty.exe", "-embedding" }));
    try std.testing.expect(!isEmbeddingArgs(&.{"noctty.exe"}));
    try std.testing.expect(!isEmbeddingArgs(&.{ "noctty.exe", "-e", "cmd.exe", "-Embedding" }));
}

test "handoff registry builders target sibling GUI executable and quote once" {
    const path = try nocttyExePathForLauncher(std.testing.allocator, "C:\\Apps\\noctty\\noctty.com");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("C:\\Apps\\noctty\\noctty.exe", path);
    const command = try localServerCommand(std.testing.allocator, path);
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("\"C:\\Apps\\noctty\\noctty.exe\"", command);
    try std.testing.expect(std.mem.indexOf(u8, command, "-Embedding") == null);
    const proxy_path = try proxyDllPathForExe(std.testing.allocator, path);
    defer std.testing.allocator.free(proxy_path);
    try std.testing.expectEqualStrings("C:\\Apps\\noctty\\" ++ proxy_filename, proxy_path);
}

test "handoff shared interface proxy ownership is exact and case insensitive" {
    try std.testing.expectEqual(@as(usize, 3), interface_proxy_registrations.len);
    try std.testing.expect(shouldRestoreInterfaceProxyText(proxy_clsid_text));
    try std.testing.expect(shouldRestoreInterfaceProxyText("{1d349824-21fb-46c7-acf3-746edc991d52}"));
    try std.testing.expect(!shouldRestoreInterfaceProxyText(null));
    try std.testing.expect(!shouldRestoreInterfaceProxyText("{3171DE52-6EFA-4AEF-8A9F-D02BD67E7A4F}"));
    for (interface_proxy_registrations) |registration| {
        try std.testing.expect(std.mem.startsWith(u8, registration.key_utf8, "Software\\Classes\\Interface\\"));
        try std.testing.expect(std.mem.endsWith(u8, registration.key_utf8, "\\ProxyStubClsid32"));
        try std.testing.expect(std.mem.startsWith(u8, registration.saved_key_utf8, saved_state_key_utf8));
    }
}

test "handoff registration refuses without compatible console half" {
    try std.testing.expectError(error.CompatibleConsoleHandoffMissing, requireCompatibleConsoleHalf(null));
    try std.testing.expectError(error.CompatibleConsoleHandoffMissing, requireCompatibleConsoleHalf(null_guid));
    try std.testing.expectError(error.CompatibleConsoleHandoffMissing, requireCompatibleConsoleHalf(inbox_console_sentinel));
    try std.testing.expectError(error.InvalidConsoleHandoff, requireCompatibleConsoleHalf("not-a-guid"));
    try requireCompatibleConsoleHalf("{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}");
}

test "handoff console classification rejects braced values with wrong dash shape" {
    // Exactly 38 chars and braced, so the length/brace guard passes and the
    // value reaches the parser. std's parseNoBraces asserts the dash positions
    // instead of erroring, so these must be rejected before it is called.
    try std.testing.expectEqual(
        ConsoleHalf.invalid,
        classifyConsoleHalf("{0123456789ABCDEF0123456789ABCDEF0123}"),
    );
    try std.testing.expectEqual(
        ConsoleHalf.invalid,
        classifyConsoleHalf("{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE6-}"),
    );
    try std.testing.expectEqual(
        ConsoleHalf.invalid,
        classifyConsoleHalf("{2EACA9477F5F--4CFA-BA87-8F7FBEEFBE69}"),
    );
    try std.testing.expectEqual(
        ConsoleHalf.invalid,
        classifyConsoleHalf("{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBEZZ}"),
    );
    try std.testing.expectEqual(
        ConsoleHalf.compatible,
        classifyConsoleHalf("{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"),
    );
}
