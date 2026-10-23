//! The COM toast activator: how a click on a noctty toast in Action Center
//! reaches noctty.
//!
//! An unpackaged app's toast keeps its in-process `Activated` handler only
//! while the popup is up. A click on an entry in Action Center (or on a toast
//! that went there directly, under Focus Assist) is delivered by COM instead:
//! Windows looks up the activator CLSID of the toast's AUMID (the
//! `CustomActivator` value of `HKCU\Software\Classes\AppUserModelId\<aumid>`,
//! or the Start menu shortcut's `System.AppUserModel.ToastActivatorCLSID`),
//! creates that class with `CLSCTX_LOCAL_SERVER` and calls
//! `INotificationActivationCallback::Activate` with the toast's launch string.
//! If no running process registered the class object, COM starts the
//! `LocalServer32` command and appends ` -Embedding` to it, so a cold start
//! sees `noctty.exe -ToastActivated -Embedding`.
//!
//! Only an installed, non-elevated copy registers anything (`shouldRegister`):
//! the installer writes the CLSID and the shortcut property, and the copy
//! writes `CustomActivator` (`win32_aumid.registerAumidDisplayName`). Portable
//! copies, and so every measure and test copy, register nothing and get
//! popup clicks only.
//!
//! The class factory and the callback object are process-lifetime statics:
//! COM may keep a proxy to either past `revoke`, and an out-of-process server
//! must outlive what it handed out. `Activate` only copies the launch string
//! and hands it to the bound `Sink`, which posts it to the UI thread's
//! toast-activation channel; it reads no App state.

const std = @import("std");
const windows = std.os.windows;
const com = @import("win32_uia/com.zig");

const log = std.log.scoped(.win32_toast_activator);
const Allocator = std.mem.Allocator;
const HRESULT = com.HRESULT;
const GUID = com.GUID;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

/// The activator's CLSID. `dist/windows/noctty.iss` registers the same value
/// (the test "installer toast activator CLSID matches the runtime" holds the
/// two together).
pub const clsid_text = "{3E21F05E-C82D-4E45-AA7D-2EC361AD6C3E}";
pub const CLSID_NOCTTY_TOAST_ACTIVATOR = GUID.parse(clsid_text);
pub const IID_INotificationActivationCallback = GUID.parse("{53E31837-6600-4A81-9395-75CFFE746F94}");
const IID_IClassFactory = GUID.parse("{00000001-0000-0000-C000-000000000046}");

/// The switch the installer's `LocalServer32` command passes. COM appends
/// `-Embedding` after it.
pub const launch_switch = "-ToastActivated";

/// Launch strings are short (`wgh://activate?surface=...&pid=...`); anything
/// longer than this is not one of ours and is delivered as empty.
pub const max_launch_bytes = 512;

const CLSCTX_LOCAL_SERVER: DWORD = 0x4;
const REGCLS_MULTIPLEUSE: DWORD = 1;
const CLASS_E_NOAGGREGATION: HRESULT = @bitCast(@as(u32, 0x80040110));

extern "ole32" fn CoRegisterClassObject(
    rclsid: *const GUID,
    object: *com.IUnknown,
    cls_context: DWORD,
    flags: DWORD,
    cookie: *DWORD,
) callconv(.winapi) HRESULT;
extern "ole32" fn CoRevokeClassObject(cookie: DWORD) callconv(.winapi) HRESULT;

/// Whether this copy registers the activator: a copy the installer put in
/// place (the CLSID's `LocalServer32` names it), not a portable copy, and not
/// elevated. An elevated noctty must not take the clicks of the user's
/// ordinary toasts, and its own pane toasts keep their popup handler.
pub fn shouldRegister(installer_managed: bool, portable: bool, elevated: bool) bool {
    return installer_managed and !portable and !elevated;
}

/// Whether argv (with argv[0]) asks for a toast activation start. Like
/// `-Embedding`, the switch counts only before `-e`, after which everything
/// belongs to the command.
pub fn hasLaunchSwitch(argv: []const []const u8) bool {
    for (argv[@min(1, argv.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "-e")) return false;
        if (std.ascii.eqlIgnoreCase(arg, launch_switch)) return true;
    }
    return false;
}

/// The `LocalServer32` command for `exe_path`: the path quoted, then the
/// switch. Caller owns the result.
pub fn localServerCommand(alloc: Allocator, exe_path: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "\"{s}\" " ++ launch_switch, .{exe_path});
}

/// Where `Activate` hands the launch string. Runs on the thread that
/// registered the class object (the UI thread's STA) inside whatever message
/// pump dispatched the call, so it must only copy or post.
pub const Sink = struct {
    ctx: *anyopaque,
    deliver: *const fn (ctx: *anyopaque, launch: []const u8) void,
    retain: ?*const fn (ctx: *anyopaque) void = null,
    release: ?*const fn (ctx: *anyopaque) void = null,
};

var sink_mutex: std.Thread.Mutex = .{};
var sink: ?Sink = null;
var cookie: ?DWORD = null;

/// Replace the sink. The new one is retained and the old one released, so a
/// call that COM delivers after the App closed its channel finds either a live
/// sink or none.
pub fn bind(new: ?Sink) void {
    if (new) |s| if (s.retain) |retain| retain(s.ctx);
    sink_mutex.lock();
    const old = sink;
    sink = new;
    sink_mutex.unlock();
    if (old) |s| if (s.release) |release| release(s.ctx);
}

pub fn isRegistered() bool {
    return cookie != null;
}

pub fn register() !void {
    if (cookie != null) return;
    var value: DWORD = 0;
    const hr = CoRegisterClassObject(
        &CLSID_NOCTTY_TOAST_ACTIVATOR,
        @ptrCast(&factory),
        CLSCTX_LOCAL_SERVER,
        REGCLS_MULTIPLEUSE,
        &value,
    );
    if (hr < 0) {
        log.warn("toast activator CoRegisterClassObject failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.ComRegistrationFailed;
    }
    cookie = value;
}

/// Revoke the class object and drop the sink.
pub fn revoke() void {
    if (cookie) |value| {
        const hr = CoRevokeClassObject(value);
        if (hr < 0) log.warn("toast activator CoRevokeClassObject failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        cookie = null;
    }
    bind(null);
}

const NOTIFICATION_USER_INPUT_DATA = extern struct {
    Key: ?[*:0]const u16,
    Value: ?[*:0]const u16,
};

pub const INotificationActivationCallback = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*INotificationActivationCallback, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*INotificationActivationCallback) callconv(.winapi) u32,
        Release: *const fn (*INotificationActivationCallback) callconv(.winapi) u32,
        Activate: *const fn (
            *INotificationActivationCallback,
            app_user_model_id: ?[*:0]const u16,
            invoked_args: ?[*:0]const u16,
            data: ?[*]const NOTIFICATION_USER_INPUT_DATA,
            count: u32,
        ) callconv(.winapi) HRESULT,
    };
};

const IClassFactory = extern struct {
    vtbl: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*IClassFactory, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IClassFactory) callconv(.winapi) u32,
        Release: *const fn (*IClassFactory) callconv(.winapi) u32,
        CreateInstance: *const fn (*IClassFactory, ?*com.IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        LockServer: *const fn (*IClassFactory, BOOL) callconv(.winapi) HRESULT,
    };
};

comptime {
    // notificationactivationcallback.h (SDK 10.0.28000.0): IUnknown's three
    // slots, then Activate(appUserModelId, invokedArgs, data, count).
    const slot = @sizeOf(*anyopaque);
    if (@offsetOf(INotificationActivationCallback.Vtbl, "Activate") != 3 * slot or
        @sizeOf(INotificationActivationCallback.Vtbl) != 4 * slot)
        @compileError("INotificationActivationCallback vtable order mismatch");
    if (@offsetOf(IClassFactory.Vtbl, "CreateInstance") != 3 * slot or
        @offsetOf(IClassFactory.Vtbl, "LockServer") != 4 * slot)
        @compileError("IClassFactory vtable order mismatch");
    if (@sizeOf(NOTIFICATION_USER_INPUT_DATA) != 2 * slot)
        @compileError("NOTIFICATION_USER_INPUT_DATA size mismatch");
}

fn iidEqual(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// Static objects: AddRef and Release count nothing, and both report a
/// reference held so no caller ever thinks it freed them.
fn staticAddRef(_: *anyopaque) u32 {
    return 2;
}

fn staticRelease(_: *anyopaque) u32 {
    return 1;
}

var callback: INotificationActivationCallback = .{ .vtbl = &callback_vtbl };
const callback_vtbl: INotificationActivationCallback.Vtbl = .{
    .QueryInterface = callbackQueryInterface,
    .AddRef = callbackAddRef,
    .Release = callbackRelease,
    .Activate = activate,
};

fn callbackQueryInterface(self: *INotificationActivationCallback, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    if (!iidEqual(iid, &com.IID_IUnknown) and !iidEqual(iid, &IID_INotificationActivationCallback)) return com.E_NOINTERFACE;
    out.* = self;
    return com.S_OK;
}

fn callbackAddRef(self: *INotificationActivationCallback) callconv(.winapi) u32 {
    return staticAddRef(self);
}

fn callbackRelease(self: *INotificationActivationCallback) callconv(.winapi) u32 {
    return staticRelease(self);
}

/// Copy `invoked_args` (the toast's `launch` attribute) and hand it to the
/// sink. A missing, oversized or ill-formed string is delivered as empty, so
/// a cold start waiting for this call still learns that it came; the sink's
/// parser rejects it. Always S_OK: the toast is consumed either way.
fn activate(
    _: *INotificationActivationCallback,
    _: ?[*:0]const u16,
    invoked_args: ?[*:0]const u16,
    _: ?[*]const NOTIFICATION_USER_INPUT_DATA,
    _: u32,
) callconv(.winapi) HRESULT {
    var buf: [max_launch_bytes]u8 = undefined;
    const launch = launchUtf8(&buf, invoked_args);
    sink_mutex.lock();
    defer sink_mutex.unlock();
    if (sink) |s| s.deliver(s.ctx, launch);
    return com.S_OK;
}

fn launchUtf8(buf: *[max_launch_bytes]u8, invoked_args: ?[*:0]const u16) []const u8 {
    const wide = std.mem.span(invoked_args orelse return "");
    var len: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(wide);
    while (it.nextCodepoint() catch return "") |cp| {
        if (len + 4 > buf.len) return "";
        len += std.unicode.utf8Encode(cp, buf[len..]) catch return "";
    }
    return buf[0..len];
}

var factory: IClassFactory = .{ .vtbl = &factory_vtbl };
const factory_vtbl: IClassFactory.Vtbl = .{
    .QueryInterface = factoryQueryInterface,
    .AddRef = factoryAddRef,
    .Release = factoryRelease,
    .CreateInstance = createInstance,
    .LockServer = lockServer,
};

fn factoryQueryInterface(self: *IClassFactory, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    if (!iidEqual(iid, &com.IID_IUnknown) and !iidEqual(iid, &IID_IClassFactory)) return com.E_NOINTERFACE;
    out.* = self;
    return com.S_OK;
}

fn factoryAddRef(self: *IClassFactory) callconv(.winapi) u32 {
    return staticAddRef(self);
}

fn factoryRelease(self: *IClassFactory) callconv(.winapi) u32 {
    return staticRelease(self);
}

fn createInstance(_: *IClassFactory, outer: ?*com.IUnknown, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    if (outer != null) return CLASS_E_NOAGGREGATION;
    return callbackQueryInterface(&callback, iid, out);
}

/// What COM gets from the class factory, for tests that drive `Activate`
/// the way COM does without registering anything.
pub fn testCallback() *INotificationActivationCallback {
    var out: ?*anyopaque = null;
    std.debug.assert(createInstance(&factory, null, &IID_INotificationActivationCallback, &out) == com.S_OK);
    return @ptrCast(@alignCast(out.?));
}

/// The process lives as long as noctty does, whatever a client locks.
fn lockServer(_: *IClassFactory, _: BOOL) callconv(.winapi) HRESULT {
    return com.S_OK;
}

test "toast activator LocalServer32 command quotes the exe and adds -ToastActivated" {
    const alloc = std.testing.allocator;
    const command = try localServerCommand(alloc, "C:\\Program Files\\noctty\\noctty.exe");
    defer alloc.free(command);
    try std.testing.expectEqualStrings("\"C:\\Program Files\\noctty\\noctty.exe\" -ToastActivated", command);
    // A cold start then sees the switch, with COM's -Embedding after it.
    try std.testing.expect(hasLaunchSwitch(&.{ "noctty.exe", "-ToastActivated", "-Embedding" }));
    try std.testing.expect(hasLaunchSwitch(&.{ "noctty.exe", "-toastactivated" }));
    try std.testing.expect(!hasLaunchSwitch(&.{ "noctty.exe", "-Embedding" }));
    try std.testing.expect(!hasLaunchSwitch(&.{ "noctty.exe", "-e", "cmd.exe", "-ToastActivated" }));
    try std.testing.expect(!hasLaunchSwitch(&.{"noctty.exe"}));
    try std.testing.expect(!hasLaunchSwitch(&.{}));
}

test "installer toast activator CLSID matches the runtime" {
    const iss = @embedFile("noctty_iss");
    const bare = clsid_text[1 .. clsid_text.len - 1];
    // The class key (Inno doubles an opening brace), its LocalServer32
    // command, and the shortcut property on both [Icons] entries.
    const class_key = "Subkey: \"Software\\Classes\\CLSID\\{" ++ clsid_text ++ "\"";
    const server_key = "Subkey: \"Software\\Classes\\CLSID\\{" ++ clsid_text ++ "\\LocalServer32\"";
    const server_value = "ValueData: \"\"\"{app}\\noctty.exe\"\" " ++ launch_switch ++ "\"";
    const shortcut = "AppUserModelToastActivatorCLSID: \"" ++ bare ++ "\"";

    var lines = std.mem.splitScalar(u8, iss, '\n');
    var class_line = false;
    var server_line = false;
    var shortcuts: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (std.mem.indexOf(u8, line, class_key) != null) {
            try std.testing.expect(std.mem.startsWith(u8, line, "Root: HKA;"));
            try std.testing.expect(std.mem.indexOf(u8, line, "Flags: uninsdeletekey") != null);
            class_line = true;
        }
        if (std.mem.indexOf(u8, line, server_key) != null) {
            try std.testing.expect(std.mem.startsWith(u8, line, "Root: HKA;"));
            try std.testing.expect(std.mem.indexOf(u8, line, "ValueName: \"\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, line, server_value) != null);
            server_line = true;
        }
        if (std.mem.startsWith(u8, line, "Name: \"{") and std.mem.indexOf(u8, line, "Filename: \"{app}\\noctty.exe\"") != null) {
            try std.testing.expect(std.mem.indexOf(u8, line, shortcut) != null);
            shortcuts += 1;
        }
    }
    try std.testing.expect(class_line);
    try std.testing.expect(server_line);
    try std.testing.expectEqual(@as(usize, 2), shortcuts);
    // Uninstall also drops the CustomActivator value that points at it.
    try std.testing.expect(std.mem.indexOf(u8, iss, "'CustomActivator'") != null);
    try std.testing.expect(std.mem.indexOf(u8, iss, "'" ++ clsid_text ++ "'") != null);
}

const TestSink = struct {
    launches: [4][max_launch_bytes]u8 = undefined,
    lens: [4]usize = undefined,
    count: usize = 0,
    retained: usize = 0,
    released: usize = 0,

    fn sinkFor(self: *TestSink) Sink {
        return .{ .ctx = self, .deliver = deliver, .retain = retain, .release = release };
    }

    fn deliver(ctx: *anyopaque, launch: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        @memcpy(self.launches[self.count][0..launch.len], launch);
        self.lens[self.count] = launch.len;
        self.count += 1;
    }

    fn retain(ctx: *anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.retained += 1;
    }

    fn release(ctx: *anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.released += 1;
    }

    fn launchAt(self: *const TestSink, i: usize) []const u8 {
        return self.launches[i][0..self.lens[i]];
    }
};

test "toast activator Activate hands the launch string to the bound sink only" {
    var test_sink: TestSink = .{};
    bind(test_sink.sinkFor());
    defer bind(null);
    try std.testing.expectEqual(@as(usize, 1), test_sink.retained);

    // COM reaches the callback through the factory, as it does in a server.
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, factory.vtbl.CreateInstance(&factory, null, &IID_INotificationActivationCallback, &out));
    const cb: *INotificationActivationCallback = @ptrCast(@alignCast(out.?));
    var unknown: ?*anyopaque = null;
    try std.testing.expectEqual(com.E_NOINTERFACE, factory.vtbl.CreateInstance(&factory, null, &IID_IClassFactory, &unknown));
    try std.testing.expectEqual(CLASS_E_NOAGGREGATION, factory.vtbl.CreateInstance(&factory, @ptrCast(&factory), &com.IID_IUnknown, &unknown));

    const aumid = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");
    const launch = std.unicode.utf8ToUtf16LeStringLiteral("wgh://activate?surface=7&pid=12&action=focus");
    try std.testing.expectEqual(com.S_OK, cb.vtbl.Activate(cb, aumid, launch, null, 0));
    try std.testing.expectEqual(com.S_OK, cb.vtbl.Activate(cb, aumid, null, null, 0));
    const long = [_:0]u16{'w'} ** (max_launch_bytes + 1);
    try std.testing.expectEqual(com.S_OK, cb.vtbl.Activate(cb, aumid, &long, null, 0));
    const unpaired = [_:0]u16{ 'w', 0xD800 };
    try std.testing.expectEqual(com.S_OK, cb.vtbl.Activate(cb, aumid, &unpaired, null, 0));
    try std.testing.expectEqual(@as(usize, 4), test_sink.count);
    try std.testing.expectEqualStrings("wgh://activate?surface=7&pid=12&action=focus", test_sink.launchAt(0));
    for (1..4) |i| try std.testing.expectEqualStrings("", test_sink.launchAt(i));

    // Unbound, a call reaches nothing.
    bind(null);
    try std.testing.expectEqual(@as(usize, 1), test_sink.released);
    try std.testing.expectEqual(com.S_OK, cb.vtbl.Activate(cb, aumid, launch, null, 0));
    try std.testing.expectEqual(@as(usize, 4), test_sink.count);
}

test "only an installed, non-elevated copy registers the toast activator" {
    try std.testing.expect(shouldRegister(true, false, false));
    try std.testing.expect(!shouldRegister(true, true, false));
    try std.testing.expect(!shouldRegister(true, false, true));
    try std.testing.expect(!shouldRegister(false, false, false));
    try std.testing.expect(!shouldRegister(false, true, true));
}
