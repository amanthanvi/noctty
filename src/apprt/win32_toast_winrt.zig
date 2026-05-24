//! WinRT bindings for Windows Action Center toasts.
//!
//! The runtime loads combase.dll dynamically and calls WinRT through raw
//! COM vtables so callers can fall back to host-local notification
//! surfaces when WinRT is unavailable. `App.init` owns
//! CoInitializeEx(STA); this layer balances RoInitialize calls that return
//! S_OK or S_FALSE.

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const HRESULT = windows.HRESULT;
const GUID = windows.GUID;
const HSTRING = *opaque {};

const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const E_NOINTERFACE: HRESULT = hresultFromU32(0x80004002);
const RPC_E_CHANGED_MODE: HRESULT = hresultFromU32(0x80010106);

fn hresultFromU32(value: u32) HRESULT {
    return @bitCast(value);
}

fn hresultToU32(value: HRESULT) u32 {
    return @bitCast(value);
}

fn winrtStringLen(len: usize) ?u32 {
    if (len > std.math.maxInt(u32)) return null;
    return @intCast(len);
}

pub const InitError = error{
    RuntimeMissing,
    WinrtUnavailable,
    NotifierCreationFailed,
    OutOfMemory,
};

pub const ShowError = error{
    XmlLoadFailed,
    ActivationFailed,
    NotifierShowFailed,
    NotifierDisabled,
    OutOfMemory,
    InvalidUtf8,
};

pub const Severity = enum { info, warn, err, success };

const NotificationSetting = enum(i32) {
    Enabled = 0,
    DisabledForApplication = 1,
    DisabledForUser = 2,
    DisabledByGroupPolicy = 3,
    DisabledByManifest = 4,
};

const IID_IUnknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");
const IID_IInspectable = GUID.parse("{AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90}");
const IID_IToastNotificationManagerStatics = GUID.parse("{50AC103F-D235-4598-BBEF-98FE4D1A3AD4}");
const IID_IToastNotificationFactory = GUID.parse("{04124B20-82C6-4229-B109-FD9ED4662B53}");
const IID_IXmlDocument = GUID.parse("{F7F3A506-1E87-42D6-BCFB-B8C809FA5494}");
const IID_IXmlDocumentIO = GUID.parse("{6CD0E74E-EE65-4489-9EBF-CA43E87BA637}");
const IID_IToastActivatedHandler = GUID.parse("{AB54DE2D-97D9-5528-B6AD-105AFE156530}");
const IID_IAgileObject = GUID.parse("{94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}");

comptime {
    if (@sizeOf(GUID) != 16) @compileError("GUID size must be 16 bytes");
}

const toast_manager_class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.Notifications.ToastNotificationManager");
const toast_notification_class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.Notifications.ToastNotification");
const xml_document_class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Data.Xml.Dom.XmlDocument");

// Vtables mirror the Windows ABI slot order. `*anyopaque` is used only
// for COM self pointers returned by WinRT.

const IInspectableVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
};

const IToastNotificationManagerStaticsVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotificationManagerStatics
    CreateToastNotifier: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateToastNotifierWithId: *const fn (*anyopaque, HSTRING, *?*anyopaque) callconv(.winapi) HRESULT,
    get_History: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const IToastNotifierVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotifier
    Show: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    Hide: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    get_Setting: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    AddToastDismissed: *const fn (*anyopaque, *anyopaque, *i64) callconv(.winapi) HRESULT,
    RemoveToastDismissed: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
    AddToastFailed: *const fn (*anyopaque, *anyopaque, *i64) callconv(.winapi) HRESULT,
    RemoveToastFailed: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
};

const IToastNotificationVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotification.
    get_Content: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    put_ExpirationTime: *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
    get_ExpirationTime: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    add_Dismissed: *const fn (*anyopaque, *anyopaque, *i64) callconv(.winapi) HRESULT,
    remove_Dismissed: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
    add_Activated: *const fn (*anyopaque, *ToastActivatedHandlerInterface, *i64) callconv(.winapi) HRESULT,
    remove_Activated: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
    add_Failed: *const fn (*anyopaque, *anyopaque, *i64) callconv(.winapi) HRESULT,
    remove_Failed: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
};

const IToastNotificationFactoryVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotificationFactory
    CreateToastNotification: *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const IXmlDocumentIOVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IXmlDocumentIO
    LoadXml: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    LoadXmlWithSettings: *const fn (*anyopaque, HSTRING, *anyopaque) callconv(.winapi) HRESULT,
};

fn ComInterface(comptime Vtbl: type) type {
    return extern struct {
        vtbl: *const Vtbl,

        const Self = @This();

        pub inline fn fromRaw(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }

        pub inline fn asRaw(self: *Self) *anyopaque {
            return @ptrCast(self);
        }

        pub inline fn queryInterface(self: *Self, iid: *const GUID, out: *?*anyopaque) HRESULT {
            return self.vtbl.QueryInterface(self.asRaw(), iid, out);
        }

        pub inline fn release(self: *Self) u32 {
            return self.vtbl.Release(self.asRaw());
        }
    };
}

const IInspectable = ComInterface(IInspectableVtbl);
const IToastNotificationManagerStatics = ComInterface(IToastNotificationManagerStaticsVtbl);
const IToastNotifier = ComInterface(IToastNotifierVtbl);
const IToastNotification = ComInterface(IToastNotificationVtbl);
const IToastNotificationFactory = ComInterface(IToastNotificationFactoryVtbl);
const IXmlDocumentIO = ComInterface(IXmlDocumentIOVtbl);

const RoInitializeFn = *const fn (u32) callconv(.winapi) HRESULT;
const RoUninitializeFn = *const fn () callconv(.winapi) void;
const RoGetActivationFactoryFn = *const fn (HSTRING, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const RoActivateInstanceFn = *const fn (HSTRING, *?*anyopaque) callconv(.winapi) HRESULT;
const WindowsCreateStringFn = *const fn (?[*]const u16, u32, *?HSTRING) callconv(.winapi) HRESULT;
const WindowsDeleteStringFn = *const fn (?HSTRING) callconv(.winapi) HRESULT;

const RO_INIT_SINGLETHREADED: u32 = 0;

const CombaseFns = struct {
    ro_init: RoInitializeFn,
    ro_uninit: RoUninitializeFn,
    ro_get_factory: RoGetActivationFactoryFn,
    ro_activate: RoActivateInstanceFn,
    create_string: WindowsCreateStringFn,
    delete_string: WindowsDeleteStringFn,
};

fn loadCombase() InitError!CombaseFns {
    const combase = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll")) orelse
        return InitError.RuntimeMissing;

    return .{
        .ro_init = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(combase, "RoInitialize") orelse
            return InitError.RuntimeMissing)),
        .ro_uninit = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(combase, "RoUninitialize") orelse
            return InitError.RuntimeMissing)),
        .ro_get_factory = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(combase, "RoGetActivationFactory") orelse
            return InitError.RuntimeMissing)),
        .ro_activate = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(combase, "RoActivateInstance") orelse
            return InitError.RuntimeMissing)),
        .create_string = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(combase, "WindowsCreateString") orelse
            return InitError.RuntimeMissing)),
        .delete_string = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(combase, "WindowsDeleteString") orelse
            return InitError.RuntimeMissing)),
    };
}

fn createHString(fns: *const CombaseFns, s: [*:0]const u16) InitError!HSTRING {
    var len: u32 = 0;
    while (s[len] != 0) len += 1;
    var hs: ?HSTRING = null;
    const hr = fns.create_string(s, len, &hs);
    if (hr < 0 or hs == null) return InitError.WinrtUnavailable;
    return hs.?;
}

fn createHStringShow(fns: *const CombaseFns, s: [*:0]const u16) ShowError!HSTRING {
    var len: u32 = 0;
    while (s[len] != 0) len += 1;
    var hs: ?HSTRING = null;
    const hr = fns.create_string(s, len, &hs);
    if (hr < 0 or hs == null) return ShowError.ActivationFailed;
    return hs.?;
}

fn createHStringFromSlice(fns: *const CombaseFns, s: []const u16) ShowError!HSTRING {
    const len = winrtStringLen(s.len) orelse return ShowError.ActivationFailed;
    var hs: ?HSTRING = null;
    const hr = fns.create_string(s.ptr, len, &hs);
    if (hr < 0 or hs == null) return ShowError.ActivationFailed;
    return hs.?;
}

/// Escape XML special characters in `input`, appending results to `writer`.
pub fn xmlEscape(writer: *std.Io.Writer, input: []const u8) std.Io.Writer.Error!void {
    for (input) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Build complete toast XML. Caller owns the returned UTF-16 slice.
/// `launch` is XML-escaped into the toast element's launch attribute so
/// click activation can recover the target surface, tab, window, and action.
fn buildToastXml(alloc: Allocator, title: []const u8, body: []const u8, severity: Severity, launch: ?[]const u8) (Allocator.Error || error{InvalidUtf8})![]const u16 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    const writer = &buf.writer;

    writer.writeAll("<toast") catch return error.OutOfMemory;
    if (launch) |l| {
        writer.writeAll(" launch=\"") catch return error.OutOfMemory;
        xmlEscape(writer, l) catch return error.OutOfMemory;
        writer.writeAll("\"") catch return error.OutOfMemory;
    }
    writer.writeAll(">") catch return error.OutOfMemory;

    switch (severity) {
        .err, .warn => writer.writeAll("<audio src=\"ms-winsoundevent:Notification.Looping.Alarm\"/>") catch return error.OutOfMemory,
        .info, .success => {},
    }

    writer.writeAll("<visual><binding template=\"ToastGeneric\"><text>") catch return error.OutOfMemory;
    xmlEscape(writer, title) catch return error.OutOfMemory;
    writer.writeAll("</text><text>") catch return error.OutOfMemory;
    xmlEscape(writer, body) catch return error.OutOfMemory;
    writer.writeAll("</text></binding></visual></toast>") catch return error.OutOfMemory;

    const utf8 = buf.written();
    const utf16_len = std.unicode.calcUtf16LeLen(utf8) catch return error.InvalidUtf8;
    const utf16_buf = try alloc.alloc(u16, utf16_len);
    errdefer alloc.free(utf16_buf);

    const result = std.unicode.utf8ToUtf16Le(utf16_buf, utf8) catch return error.InvalidUtf8;
    _ = result;

    return utf16_buf;
}

/// HRESULTs accepted from RoInitialize on the app's existing COM apartment.
pub fn isRoInitSuccess(hr: HRESULT) bool {
    return hr == S_OK or hr == S_FALSE or hr == RPC_E_CHANGED_MODE;
}

fn roInitializeNeedsUninitialize(hr: HRESULT) bool {
    return hr == S_OK or hr == S_FALSE;
}

fn notificationSettingFromInt(value: i32) ?NotificationSetting {
    return switch (value) {
        @intFromEnum(NotificationSetting.Enabled) => .Enabled,
        @intFromEnum(NotificationSetting.DisabledForApplication) => .DisabledForApplication,
        @intFromEnum(NotificationSetting.DisabledForUser) => .DisabledForUser,
        @intFromEnum(NotificationSetting.DisabledByGroupPolicy) => .DisabledByGroupPolicy,
        @intFromEnum(NotificationSetting.DisabledByManifest) => .DisabledByManifest,
        else => null,
    };
}

fn notifierSettingAllowsDisplay(setting: NotificationSetting) bool {
    return setting == .Enabled;
}

fn iidEqual(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// Callback invoked when a toast with a launch attribute is clicked.
/// `launch` is handler-owned and valid only for the callback duration;
/// copy it before returning if the data must be retained.
pub const ActivationCallback = *const fn (ctx: *anyopaque, launch: []const u8) void;

const ToastActivatedHandlerInterface = extern struct {
    vtbl: *const ToastActivatedHandlerVtbl,

    fn fromRaw(raw: *anyopaque) *ToastActivatedHandlerInterface {
        return @ptrCast(@alignCast(raw));
    }

    fn asRaw(self: *ToastActivatedHandlerInterface) *anyopaque {
        return @ptrCast(self);
    }
};

const ToastActivatedHandlerVtbl = extern struct {
    QueryInterface: *const fn (*ToastActivatedHandlerInterface, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ToastActivatedHandlerInterface) callconv(.winapi) u32,
    Release: *const fn (*ToastActivatedHandlerInterface) callconv(.winapi) u32,
    Invoke: *const fn (*ToastActivatedHandlerInterface, *anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
};

const ToastActivationHandler = struct {
    base: ToastActivatedHandlerInterface,
    refcount: std.atomic.Value(u32),
    launch: []u8,
    callback: ActivationCallback,
    ctx: *anyopaque,

    const alloc = std.heap.page_allocator;

    const vtbl: ToastActivatedHandlerVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .Invoke = Invoke,
    };

    fn create(launch: []const u8, callback: ActivationCallback, ctx: *anyopaque) Allocator.Error!*ToastActivationHandler {
        const launch_copy = try alloc.dupe(u8, launch);
        errdefer alloc.free(launch_copy);

        const self = try alloc.create(ToastActivationHandler);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .launch = launch_copy,
            .callback = callback,
            .ctx = ctx,
        };
        return self;
    }

    fn fromBase(base: *ToastActivatedHandlerInterface) *ToastActivationHandler {
        return @fieldParentPtr("base", base);
    }

    fn QueryInterface(
        base: *ToastActivatedHandlerInterface,
        iid: *const GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        const self = fromBase(base);
        out.* = null;
        if (iidEqual(iid, &IID_IUnknown) or
            iidEqual(iid, &IID_IToastActivatedHandler) or
            iidEqual(iid, &IID_IAgileObject))
        {
            out.* = self.base.asRaw();
            _ = self.refcount.fetchAdd(1, .monotonic);
            return S_OK;
        }

        return E_NOINTERFACE;
    }

    fn AddRef(base: *ToastActivatedHandlerInterface) callconv(.winapi) u32 {
        const self = fromBase(base);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Release(base: *ToastActivatedHandlerInterface) callconv(.winapi) u32 {
        const self = fromBase(base);
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            alloc.free(self.launch);
            alloc.destroy(self);
            return 0;
        }

        return prev - 1;
    }

    fn Invoke(
        base: *ToastActivatedHandlerInterface,
        _: *anyopaque,
        _: ?*anyopaque,
    ) callconv(.winapi) HRESULT {
        const self = fromBase(base);
        // The callback must copy launch if it needs to retain the value.
        self.callback(self.ctx, self.launch);
        return S_OK;
    }
};

pub const WinrtToast = struct {
    alloc: Allocator,
    fns: CombaseFns,
    notifier: *IToastNotifier,
    aumid_hs: HSTRING,
    ro_initialized: bool,
    activation_callback: ?ActivationCallback = null,
    activation_ctx: ?*anyopaque = null,

    pub fn init(alloc: Allocator, aumid: []const u16) InitError!WinrtToast {
        const fns = try loadCombase();

        const ro_hr = fns.ro_init(RO_INIT_SINGLETHREADED);
        const ro_initialized = isRoInitSuccess(ro_hr);
        const ro_uninit_needed = roInitializeNeedsUninitialize(ro_hr);
        if (!ro_initialized and ro_hr < 0 and ro_hr != RPC_E_CHANGED_MODE) {
            return InitError.WinrtUnavailable;
        }
        errdefer if (ro_uninit_needed) fns.ro_uninit();

        const manager_hs = try createHString(&fns, toast_manager_class);
        defer _ = fns.delete_string(manager_hs);

        var factory_raw: ?*anyopaque = null;
        const factory_hr = fns.ro_get_factory(manager_hs, &IID_IToastNotificationManagerStatics, &factory_raw);
        if (factory_hr < 0 or factory_raw == null) return InitError.WinrtUnavailable;

        const factory = IToastNotificationManagerStatics.fromRaw(factory_raw.?);
        defer _ = factory.release();

        const aumid_len = winrtStringLen(aumid.len) orelse return InitError.NotifierCreationFailed;
        var aumid_hs: ?HSTRING = null;
        const hs_hr = fns.create_string(aumid.ptr, aumid_len, &aumid_hs);
        if (hs_hr < 0 or aumid_hs == null) return InitError.NotifierCreationFailed;
        errdefer _ = fns.delete_string(aumid_hs.?);

        var notifier_raw: ?*anyopaque = null;
        const notifier_hr = factory.vtbl.CreateToastNotifierWithId(factory.asRaw(), aumid_hs.?, &notifier_raw);
        if (notifier_hr < 0 or notifier_raw == null) return InitError.NotifierCreationFailed;

        return .{
            .alloc = alloc,
            .fns = fns,
            .notifier = IToastNotifier.fromRaw(notifier_raw.?),
            .aumid_hs = aumid_hs.?,
            .ro_initialized = ro_uninit_needed,
        };
    }

    pub fn setActivationCallback(self: *WinrtToast, ctx: *anyopaque, callback: ActivationCallback) void {
        self.activation_ctx = ctx;
        self.activation_callback = callback;
    }

    pub fn deinit(self: *WinrtToast) void {
        _ = self.notifier.release();
        _ = self.fns.delete_string(self.aumid_hs);
        if (self.ro_initialized) self.fns.ro_uninit();
        self.* = undefined;
    }

    pub fn show(self: *WinrtToast, title: []const u8, body: []const u8, severity: Severity) ShowError!void {
        return self.showWithLaunch(title, body, severity, null);
    }

    /// Show a toast with an optional launch string for click activation.
    /// `null` produces a generic toast with no target context.
    pub fn showWithLaunch(
        self: *WinrtToast,
        title: []const u8,
        body: []const u8,
        severity: Severity,
        launch: ?[]const u8,
    ) ShowError!void {
        const xml_utf16 = buildToastXml(self.alloc, title, body, severity, launch) catch |e| switch (e) {
            error.OutOfMemory => return ShowError.OutOfMemory,
            error.InvalidUtf8 => return ShowError.InvalidUtf8,
        };
        defer self.alloc.free(xml_utf16);

        const xml_class_hs = try createHStringShow(&self.fns, xml_document_class);
        defer _ = self.fns.delete_string(xml_class_hs);

        var xml_inspectable_raw: ?*anyopaque = null;
        const act_hr = self.fns.ro_activate(xml_class_hs, &xml_inspectable_raw);
        if (act_hr < 0 or xml_inspectable_raw == null) return ShowError.ActivationFailed;

        const xml_inspectable = IInspectable.fromRaw(xml_inspectable_raw.?);
        defer _ = xml_inspectable.release();

        var xml_io_raw: ?*anyopaque = null;
        const qi_hr = xml_inspectable.queryInterface(&IID_IXmlDocumentIO, &xml_io_raw);
        if (qi_hr < 0 or xml_io_raw == null) return ShowError.XmlLoadFailed;

        const xml_io = IXmlDocumentIO.fromRaw(xml_io_raw.?);
        defer _ = xml_io.release();

        const xml_hs = try createHStringFromSlice(&self.fns, xml_utf16);
        defer _ = self.fns.delete_string(xml_hs);

        const load_hr = xml_io.vtbl.LoadXml(xml_io.asRaw(), xml_hs);
        if (load_hr < 0) return ShowError.XmlLoadFailed;

        var xml_doc_raw: ?*anyopaque = null;
        const doc_hr = xml_inspectable.queryInterface(&IID_IXmlDocument, &xml_doc_raw);
        if (doc_hr < 0 or xml_doc_raw == null) return ShowError.XmlLoadFailed;

        const xml_doc = IInspectable.fromRaw(xml_doc_raw.?);
        defer _ = xml_doc.release();

        const toast_class_hs = try createHStringShow(&self.fns, toast_notification_class);
        defer _ = self.fns.delete_string(toast_class_hs);

        var toast_factory_raw: ?*anyopaque = null;
        const tf_hr = self.fns.ro_get_factory(toast_class_hs, &IID_IToastNotificationFactory, &toast_factory_raw);
        if (tf_hr < 0 or toast_factory_raw == null) return ShowError.ActivationFailed;

        const toast_factory = IToastNotificationFactory.fromRaw(toast_factory_raw.?);
        defer _ = toast_factory.release();

        var notification_raw: ?*anyopaque = null;
        const cn_hr = toast_factory.vtbl.CreateToastNotification(toast_factory.asRaw(), xml_doc.asRaw(), &notification_raw);
        if (cn_hr < 0 or notification_raw == null) return ShowError.ActivationFailed;

        const notification = IToastNotification.fromRaw(notification_raw.?);
        defer _ = notification.release();

        var setting_value: i32 = 0;
        const setting_hr = self.notifier.vtbl.get_Setting(self.notifier.asRaw(), &setting_value);
        if (setting_hr >= 0) {
            const setting = notificationSettingFromInt(setting_value) orelse {
                std.log.warn("winrt toast: unrecognized notifier setting={d}; falling back", .{setting_value});
                return ShowError.NotifierDisabled;
            };
            if (!notifierSettingAllowsDisplay(setting)) return ShowError.NotifierDisabled;
        }

        if (launch) |value| {
            if (self.activation_callback == null or self.activation_ctx == null) {
                std.log.warn("winrt toast activation callback/context missing for launch toast", .{});
                return ShowError.ActivationFailed;
            }
            const callback = self.activation_callback.?;
            const ctx = self.activation_ctx.?;
            const handler = ToastActivationHandler.create(value, callback, ctx) catch return ShowError.OutOfMemory;
            var token: i64 = 0;
            const add_hr = notification.vtbl.add_Activated(notification.asRaw(), &handler.base, &token);
            _ = handler.base.vtbl.Release(&handler.base);
            if (add_hr < 0) {
                std.log.warn("winrt toast activation handler registration failed hr=0x{x:0>8}", .{
                    hresultToU32(add_hr),
                });
                return ShowError.ActivationFailed;
            }
        }

        const show_hr = self.notifier.vtbl.Show(self.notifier.asRaw(), notification.asRaw());
        if (show_hr < 0) return ShowError.NotifierShowFailed;
    }
};

test "WinrtToast xml escaping - ampersand" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try xmlEscape(&buf.writer, "Tom & Jerry");
    try std.testing.expectEqualStrings("Tom &amp; Jerry", buf.written());
}

test "WinrtToast xml escaping - angle brackets" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try xmlEscape(&buf.writer, "<script>alert('xss')</script>");
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&apos;xss&apos;)&lt;/script&gt;", buf.written());
}

test "WinrtToast xml escaping - quotes" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try xmlEscape(&buf.writer, "He said \"hello\"");
    try std.testing.expectEqualStrings("He said &quot;hello&quot;", buf.written());
}

test "WinrtToast xml escaping - all special chars" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try xmlEscape(&buf.writer, "&<>\"'");
    try std.testing.expectEqualStrings("&amp;&lt;&gt;&quot;&apos;", buf.written());
}

test "WinrtToast xml escaping - passthrough plain text" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try xmlEscape(&buf.writer, "Hello World 123");
    try std.testing.expectEqualStrings("Hello World 123", buf.written());
}

test "WinrtToast xml escaping - empty string" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try xmlEscape(&buf.writer, "");
    try std.testing.expectEqual(@as(usize, 0), buf.written().len);
}

test "WinrtToast HRESULT classification - S_OK is success" {
    try std.testing.expect(isRoInitSuccess(S_OK));
}

test "WinrtToast HRESULT classification - S_FALSE is success" {
    try std.testing.expect(isRoInitSuccess(S_FALSE));
}

test "WinrtToast HRESULT classification - RPC_E_CHANGED_MODE is success" {
    try std.testing.expect(isRoInitSuccess(RPC_E_CHANGED_MODE));
}

test "WinrtToast notifier setting gate only allows Enabled" {
    try std.testing.expectEqual(NotificationSetting.Enabled, notificationSettingFromInt(0).?);
    try std.testing.expectEqual(NotificationSetting.DisabledForApplication, notificationSettingFromInt(1).?);
    try std.testing.expectEqual(NotificationSetting.DisabledForUser, notificationSettingFromInt(2).?);
    try std.testing.expectEqual(NotificationSetting.DisabledByGroupPolicy, notificationSettingFromInt(3).?);
    try std.testing.expectEqual(NotificationSetting.DisabledByManifest, notificationSettingFromInt(4).?);
    try std.testing.expect(notificationSettingFromInt(99) == null);

    try std.testing.expect(notifierSettingAllowsDisplay(.Enabled));
    try std.testing.expect(!notifierSettingAllowsDisplay(.DisabledForApplication));
    try std.testing.expect(!notifierSettingAllowsDisplay(.DisabledForUser));
    try std.testing.expect(!notifierSettingAllowsDisplay(.DisabledByGroupPolicy));
    try std.testing.expect(!notifierSettingAllowsDisplay(.DisabledByManifest));
}

test "WinrtToast activation handler supports QI and invokes launch callback" {
    const State = struct {
        called: bool = false,

        fn callback(ctx: *anyopaque, launch: []const u8) void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.called = std.mem.eql(u8, launch, "wgh://activate?surface=7&action=focus");
        }
    };

    var state = State{};
    const handler = try ToastActivationHandler.create(
        "wgh://activate?surface=7&action=focus",
        State.callback,
        &state,
    );

    var out: ?*anyopaque = null;
    try std.testing.expectEqual(S_OK, handler.base.vtbl.QueryInterface(&handler.base, &IID_IToastActivatedHandler, &out));
    try std.testing.expect(out != null);
    const queried = ToastActivatedHandlerInterface.fromRaw(out.?);
    try std.testing.expectEqual(@as(u32, 1), queried.vtbl.Release(queried));

    try std.testing.expectEqual(S_OK, handler.base.vtbl.QueryInterface(&handler.base, &IID_IAgileObject, &out));
    try std.testing.expect(out != null);
    const agile = ToastActivatedHandlerInterface.fromRaw(out.?);
    try std.testing.expectEqual(@as(u32, 1), agile.vtbl.Release(agile));

    try std.testing.expectEqual(E_NOINTERFACE, handler.base.vtbl.QueryInterface(&handler.base, &IID_IInspectable, &out));
    try std.testing.expect(out == null);

    try std.testing.expectEqual(S_OK, handler.base.vtbl.Invoke(&handler.base, @ptrFromInt(1), null));
    try std.testing.expect(state.called);
    try std.testing.expectEqual(@as(u32, 0), handler.base.vtbl.Release(&handler.base));
}

test "WinrtToast HRESULT classification - negative codes are failure" {
    const E_FAIL: HRESULT = hresultFromU32(0x80004005);
    const E_NOTIMPL: HRESULT = hresultFromU32(0x80004001);
    try std.testing.expect(!isRoInitSuccess(E_FAIL));
    try std.testing.expect(!isRoInitSuccess(E_NOTIMPL));
}

test "WinrtToast HRESULT classification - arbitrary positive not success" {
    try std.testing.expect(!isRoInitSuccess(2));
    try std.testing.expect(!isRoInitSuccess(42));
}

test "WinrtToast WinRT string lengths are bounded to u32" {
    try std.testing.expectEqual(@as(?u32, 0), winrtStringLen(0));
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), winrtStringLen(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(?u32, null), winrtStringLen(@as(usize, std.math.maxInt(u32)) + 1));
}

test "WinrtToast buildToastXml - info severity no audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "Title", "Body", .info, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") == null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "<text>Title</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "<text>Body</text>") != null);
}

test "WinrtToast buildToastXml - err severity has audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "Error", "Oops", .err, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio src=\"ms-winsoundevent:Notification.Looping.Alarm\"") != null);
}

test "WinrtToast buildToastXml - warn severity has audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "Warning", "Careful", .warn, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") != null);
}

test "WinrtToast buildToastXml - success severity no audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "Done", "All good", .success, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") == null);
}

test "WinrtToast buildToastXml - escapes special chars in title and body" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "A & B", "<tag>", .info, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "&lt;tag&gt;") != null);
    // Raw XML metacharacters are only valid in markup, not text nodes.
    const text_start = std.mem.indexOf(u8, utf8, "<text>").?;
    const text_end = std.mem.indexOfPos(u8, utf8, text_start, "</text>").?;
    const first_text = utf8[text_start + 6 .. text_end];
    try std.testing.expectEqualStrings("A &amp; B", first_text);
}

test "WinrtToast buildToastXml - valid XML structure" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "T", "B", .info, null);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.startsWith(u8, utf8, "<toast>"));
    try std.testing.expect(std.mem.endsWith(u8, utf8, "</toast>"));
    try std.testing.expect(std.mem.indexOf(u8, utf8, "template=\"ToastGeneric\"") != null);
}

test "WinrtToast buildToastXml - includes launch attribute when provided" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "T", "B", .info, "wgh://activate?surface=42");
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.startsWith(u8, utf8, "<toast launch=\""));
    try std.testing.expect(std.mem.indexOf(u8, utf8, "wgh://activate?surface=42") != null);
}

test "WinrtToast buildToastXml - launch attribute is XML-escaped" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, "T", "B", .info, "wgh://activate?surface=1&tab=2");
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    // A raw `&` in the query string would abort WinRT XML parsing.
    try std.testing.expect(std.mem.indexOf(u8, utf8, "surface=1&amp;tab=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "surface=1&tab=2\"") == null);
}

test "WinrtToast GUID sizes are 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IInspectable)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IToastNotificationManagerStatics)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IToastNotificationFactory)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IXmlDocument)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IXmlDocumentIO)));
}

test "WinrtToast COM interface wrappers have vtbl pointer at offset 0" {
    // COM requires the vtbl pointer at offset 0.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IInspectable, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IToastNotificationManagerStatics, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IToastNotifier, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IToastNotification, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IToastNotificationFactory, "vtbl"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(IXmlDocumentIO, "vtbl"));
}

test "WinrtToast RoInitialize success and teardown tracking" {
    try std.testing.expect(isRoInitSuccess(S_OK));
    try std.testing.expect(isRoInitSuccess(S_FALSE));
    try std.testing.expect(isRoInitSuccess(RPC_E_CHANGED_MODE));

    try std.testing.expect(roInitializeNeedsUninitialize(S_OK));
    try std.testing.expect(roInitializeNeedsUninitialize(S_FALSE));
    try std.testing.expect(!roInitializeNeedsUninitialize(RPC_E_CHANGED_MODE));
}

test "WinrtToast ComInterface wrapper size equals pointer size" {
    // COM interfaces are a single vtbl pointer in the ABI.
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(IInspectable));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(IToastNotifier));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(IXmlDocumentIO));
}
