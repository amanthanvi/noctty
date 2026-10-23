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

pub const HistoryError = error{
    HistoryUnavailable,
    RemoveFailed,
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
const IID_IToastNotificationManagerStatics2 = GUID.parse("{7AB93C52-0E48-4750-BA9D-1A4113981847}");
const IID_IToastNotification2 = GUID.parse("{9DFB9FD1-143A-490E-90BF-B9FBA7132DE7}");
const IID_IToastNotificationHistory = GUID.parse("{5CADDC63-01D3-4C97-986F-0533483FEE14}");
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
    // IToastNotificationManagerStatics. `get_History` is not here: it is
    // the only method of IToastNotificationManagerStatics2.
    CreateToastNotifier: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateToastNotifierWithId: *const fn (*anyopaque, HSTRING, *?*anyopaque) callconv(.winapi) HRESULT,
    GetTemplateContent: *const fn (*anyopaque, i32, *?*anyopaque) callconv(.winapi) HRESULT,
};

const IToastNotificationManagerStatics2Vtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotificationManagerStatics2
    get_History: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const IToastNotificationHistoryVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotificationHistory. Only the `WithId` removals are called: an
    // unpackaged app names its AUMID. `Clear` and `ClearWithId` are here for
    // the slot order only and are never called, because every noctty
    // process (installed and portable) shares the AUMID and they would
    // delete the other processes' toasts too.
    RemoveGroup: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    RemoveGroupWithId: *const fn (*anyopaque, HSTRING, HSTRING) callconv(.winapi) HRESULT,
    RemoveGroupedTagWithId: *const fn (*anyopaque, HSTRING, HSTRING, HSTRING) callconv(.winapi) HRESULT,
    RemoveGroupedTag: *const fn (*anyopaque, HSTRING, HSTRING) callconv(.winapi) HRESULT,
    Remove: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    Clear: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    ClearWithId: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
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

const IToastNotification2Vtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IInspectable (3)
    GetIids: *const fn (*anyopaque, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    // IToastNotification2
    put_Tag: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    get_Tag: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    put_Group: *const fn (*anyopaque, HSTRING) callconv(.winapi) HRESULT,
    get_Group: *const fn (*anyopaque, *?HSTRING) callconv(.winapi) HRESULT,
    put_SuppressPopup: *const fn (*anyopaque, u8) callconv(.winapi) HRESULT,
    get_SuppressPopup: *const fn (*anyopaque, *u8) callconv(.winapi) HRESULT,
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
const IToastNotificationManagerStatics2 = ComInterface(IToastNotificationManagerStatics2Vtbl);
const IToastNotificationHistory = ComInterface(IToastNotificationHistoryVtbl);
const IToastNotifier = ComInterface(IToastNotifierVtbl);
const IToastNotification = ComInterface(IToastNotificationVtbl);
const IToastNotification2 = ComInterface(IToastNotification2Vtbl);
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

fn createHStringFromUtf8(alloc: Allocator, fns: *const CombaseFns, s: []const u8) error{ OutOfMemory, InvalidUtf8, ActivationFailed }!HSTRING {
    const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, s) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf8,
    };
    defer alloc.free(wide);
    return createHStringFromSlice(fns, wide) catch error.ActivationFailed;
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

/// What one toast shows. Every slice is borrowed for the call.
pub const ToastRequest = struct {
    title: []const u8,
    /// Shown under the title; an empty body shows no line.
    body: []const u8,
    /// noctty's own line at the bottom of the toast
    /// (`<text placement="attribution">`, Windows 10 1607 and later),
    /// styled apart from the program's text: which tab the toast is from.
    attribution: ?[]const u8 = null,
    /// The toast element's launch argument, for click activation.
    launch: ?[]const u8 = null,
    /// `ToastNotification.Tag` and `.Group`: a newer toast with the same
    /// pair replaces the older one in Action Center, and
    /// `WinrtToast.removeGroupedTag` / `removeGroup` remove them.
    tag: ?[]const u8 = null,
    group: ?[]const u8 = null,
};

/// Build complete toast XML. Caller owns the returned UTF-16 slice.
/// Every string is XML-escaped; `launch` goes into the toast element's
/// launch attribute so click activation can recover the target surface,
/// tab, window, and action.
fn buildToastXml(alloc: Allocator, request: ToastRequest, severity: Severity) (Allocator.Error || error{InvalidUtf8})![]const u16 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    const writer = &buf.writer;

    writer.writeAll("<toast") catch return error.OutOfMemory;
    if (request.launch) |l| {
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
    xmlEscape(writer, request.title) catch return error.OutOfMemory;
    writer.writeAll("</text>") catch return error.OutOfMemory;
    if (request.body.len > 0) {
        writer.writeAll("<text>") catch return error.OutOfMemory;
        xmlEscape(writer, request.body) catch return error.OutOfMemory;
        writer.writeAll("</text>") catch return error.OutOfMemory;
    }
    if (request.attribution) |attribution| {
        writer.writeAll("<text placement=\"attribution\">") catch return error.OutOfMemory;
        xmlEscape(writer, attribution) catch return error.OutOfMemory;
        writer.writeAll("</text>") catch return error.OutOfMemory;
    }
    writer.writeAll("</binding></visual></toast>") catch return error.OutOfMemory;

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

/// Agile activation handlers can outlive the notifier and its UI owner.
pub const ActivationContextLifetime = struct {
    retain: *const fn (*anyopaque) void,
    release: *const fn (*anyopaque) void,
};

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
    context_lifetime: ?ActivationContextLifetime,

    const alloc = std.heap.page_allocator;

    const vtbl: ToastActivatedHandlerVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .Invoke = Invoke,
    };

    fn create(launch: []const u8, callback: ActivationCallback, ctx: *anyopaque, lifetime: ?ActivationContextLifetime) Allocator.Error!*ToastActivationHandler {
        const launch_copy = try alloc.dupe(u8, launch);
        errdefer alloc.free(launch_copy);

        const self = try alloc.create(ToastActivationHandler);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .launch = launch_copy,
            .callback = callback,
            .ctx = ctx,
            .context_lifetime = lifetime,
        };
        if (lifetime) |owned| owned.retain(ctx);
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
            if (self.context_lifetime) |owned| owned.release(self.ctx);
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
    activation_context_lifetime: ?ActivationContextLifetime = null,

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

    pub fn setActivationCallback(self: *WinrtToast, ctx: *anyopaque, callback: ActivationCallback, lifetime: ActivationContextLifetime) void {
        lifetime.retain(ctx);
        if (self.activation_context_lifetime) |old| old.release(self.activation_ctx.?);
        self.activation_ctx = ctx;
        self.activation_callback = callback;
        self.activation_context_lifetime = lifetime;
    }

    pub fn deinit(self: *WinrtToast) void {
        _ = self.notifier.release();
        if (self.activation_context_lifetime) |owned| owned.release(self.activation_ctx.?);
        _ = self.fns.delete_string(self.aumid_hs);
        if (self.ro_initialized) self.fns.ro_uninit();
        self.* = undefined;
    }

    /// Show a toast. A request with a launch string gets a click handler
    /// that hands the string to the activation callback; one without is a
    /// generic toast with no target context.
    pub fn show(self: *WinrtToast, request: ToastRequest, severity: Severity) ShowError!void {
        const xml_utf16 = buildToastXml(self.alloc, request, severity) catch |e| switch (e) {
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

        if (request.launch) |value| {
            if (self.activation_callback == null or self.activation_ctx == null) {
                std.log.warn("winrt toast activation callback/context missing for launch toast", .{});
                return ShowError.ActivationFailed;
            }
            const callback = self.activation_callback.?;
            const ctx = self.activation_ctx.?;
            const handler = ToastActivationHandler.create(value, callback, ctx, self.activation_context_lifetime) catch return ShowError.OutOfMemory;
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

        if (request.tag != null or request.group != null) self.applyTagAndGroup(notification, request);

        const show_hr = self.notifier.vtbl.Show(self.notifier.asRaw(), notification.asRaw());
        if (show_hr < 0) return ShowError.NotifierShowFailed;
    }

    /// Set the toast's Tag and Group (`IToastNotification2`). A failure is
    /// logged and the toast is shown untagged: it then neither replaces an
    /// older toast nor is removed by tag, which is how every toast behaved
    /// before.
    fn applyTagAndGroup(self: *WinrtToast, notification: *IToastNotification, request: ToastRequest) void {
        var raw: ?*anyopaque = null;
        const qi_hr = notification.queryInterface(&IID_IToastNotification2, &raw);
        if (qi_hr < 0 or raw == null) {
            std.log.warn("winrt toast: IToastNotification2 unavailable hr=0x{x:0>8}; shown untagged", .{hresultToU32(qi_hr)});
            return;
        }
        const toast2 = IToastNotification2.fromRaw(raw.?);
        defer _ = toast2.release();
        inline for (.{ .{ "tag", "put_Tag" }, .{ "group", "put_Group" } }) |pair| {
            if (@field(request, pair[0])) |value| {
                const hs = createHStringFromUtf8(self.alloc, &self.fns, value) catch |err| {
                    std.log.warn("winrt toast: " ++ pair[0] ++ " not set err={}", .{err});
                    return;
                };
                defer _ = self.fns.delete_string(hs);
                const hr = @field(toast2.vtbl, pair[1])(toast2.asRaw(), hs);
                if (hr < 0) {
                    std.log.warn("winrt toast: " ++ pair[1] ++ " failed hr=0x{x:0>8}", .{hresultToU32(hr)});
                    return;
                }
            }
        }
    }

    /// Remove the toast tagged `tag` in `group` from Action Center, if it
    /// is still there. Only this AUMID's toasts are searched.
    pub fn removeGroupedTag(self: *WinrtToast, tag: []const u8, group: []const u8) HistoryError!void {
        const history = try self.openHistory();
        defer _ = history.release();
        const tag_hs = createHStringFromUtf8(self.alloc, &self.fns, tag) catch |err| return historyStringError(err);
        defer _ = self.fns.delete_string(tag_hs);
        const group_hs = createHStringFromUtf8(self.alloc, &self.fns, group) catch |err| return historyStringError(err);
        defer _ = self.fns.delete_string(group_hs);
        const hr = history.vtbl.RemoveGroupedTagWithId(history.asRaw(), tag_hs, group_hs, self.aumid_hs);
        if (hr < 0) return HistoryError.RemoveFailed;
    }

    /// Remove every toast in `group` from Action Center. Only this AUMID's
    /// toasts are searched, and the group names one process, so other
    /// noctty processes keep theirs.
    pub fn removeGroup(self: *WinrtToast, group: []const u8) HistoryError!void {
        const history = try self.openHistory();
        defer _ = history.release();
        const group_hs = createHStringFromUtf8(self.alloc, &self.fns, group) catch |err| return historyStringError(err);
        defer _ = self.fns.delete_string(group_hs);
        const hr = history.vtbl.RemoveGroupWithId(history.asRaw(), group_hs, self.aumid_hs);
        if (hr < 0) return HistoryError.RemoveFailed;
    }

    /// `ToastNotificationManager.History`. The caller releases it.
    fn openHistory(self: *WinrtToast) HistoryError!*IToastNotificationHistory {
        const manager_hs = createHStringShow(&self.fns, toast_manager_class) catch return HistoryError.HistoryUnavailable;
        defer _ = self.fns.delete_string(manager_hs);
        var statics_raw: ?*anyopaque = null;
        const factory_hr = self.fns.ro_get_factory(manager_hs, &IID_IToastNotificationManagerStatics2, &statics_raw);
        if (factory_hr < 0 or statics_raw == null) return HistoryError.HistoryUnavailable;
        const statics = IToastNotificationManagerStatics2.fromRaw(statics_raw.?);
        defer _ = statics.release();
        var history_raw: ?*anyopaque = null;
        const hr = statics.vtbl.get_History(statics.asRaw(), &history_raw);
        if (hr < 0 or history_raw == null) return HistoryError.HistoryUnavailable;
        return IToastNotificationHistory.fromRaw(history_raw.?);
    }

    fn historyStringError(err: error{ OutOfMemory, InvalidUtf8, ActivationFailed }) HistoryError {
        return switch (err) {
            error.OutOfMemory => HistoryError.OutOfMemory,
            error.InvalidUtf8 => HistoryError.InvalidUtf8,
            error.ActivationFailed => HistoryError.RemoveFailed,
        };
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
        null,
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

test "WinrtToast agile activation retains context beyond its UI owner" {
    const State = struct {
        refs: usize = 1,
        observer: *Observer,
        const Observer = struct { called: bool = false, destroyed: bool = false };

        fn retain(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.refs += 1;
        }
        fn release(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.refs -= 1;
            if (self.refs != 0) return;
            self.observer.destroyed = true;
            std.testing.allocator.destroy(self);
        }
        fn callback(raw: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.refs > 0);
            self.observer.called = true;
        }
    };
    var observer: State.Observer = .{};
    const state = try std.testing.allocator.create(State);
    state.* = .{ .observer = &observer };
    const handler = try ToastActivationHandler.create("activation", State.callback, state, .{
        .retain = State.retain,
        .release = State.release,
    });
    State.release(state); // The UI owner is gone, but WinRT still has its handler.
    try std.testing.expect(!observer.destroyed);
    try std.testing.expectEqual(S_OK, handler.base.vtbl.Invoke(&handler.base, @ptrFromInt(1), null));
    try std.testing.expect(observer.called);
    _ = handler.base.vtbl.Release(&handler.base);
    try std.testing.expect(observer.destroyed);
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
    const xml = try buildToastXml(alloc, .{ .title = "Title", .body = "Body" }, .info);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") == null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "<text>Title</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "<text>Body</text>") != null);
}

test "WinrtToast buildToastXml - err severity has audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, .{ .title = "Error", .body = "Oops" }, .err);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio src=\"ms-winsoundevent:Notification.Looping.Alarm\"") != null);
}

test "WinrtToast buildToastXml - warn severity has audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, .{ .title = "Warning", .body = "Careful" }, .warn);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") != null);
}

test "WinrtToast buildToastXml - success severity no audio" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, .{ .title = "Done", .body = "All good" }, .success);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.indexOf(u8, utf8, "<audio") == null);
}

test "WinrtToast buildToastXml - escapes special chars in title and body" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, .{ .title = "A & B", .body = "<tag>" }, .info);
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
    const xml = try buildToastXml(alloc, .{ .title = "T", .body = "B" }, .info);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.startsWith(u8, utf8, "<toast>"));
    try std.testing.expect(std.mem.endsWith(u8, utf8, "</toast>"));
    try std.testing.expect(std.mem.indexOf(u8, utf8, "template=\"ToastGeneric\"") != null);
}

test "WinrtToast buildToastXml - includes launch attribute when provided" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, .{ .title = "T", .body = "B", .launch = "wgh://activate?surface=42" }, .info);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    try std.testing.expect(std.mem.startsWith(u8, utf8, "<toast launch=\""));
    try std.testing.expect(std.mem.indexOf(u8, utf8, "wgh://activate?surface=42") != null);
}

test "WinrtToast buildToastXml - launch attribute is XML-escaped" {
    const alloc = std.testing.allocator;
    const xml = try buildToastXml(alloc, .{ .title = "T", .body = "B", .launch = "wgh://activate?surface=1&tab=2" }, .info);
    defer alloc.free(xml);

    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);

    // A raw `&` in the query string would abort WinRT XML parsing.
    try std.testing.expect(std.mem.indexOf(u8, utf8, "surface=1&amp;tab=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "surface=1&tab=2\"") == null);
}

test "buildToastXml emits an escaped attribution line only when given one" {
    const alloc = std.testing.allocator;

    const plain = try buildToastXml(alloc, .{ .title = "T", .body = "B" }, .info);
    defer alloc.free(plain);
    const plain_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, plain);
    defer alloc.free(plain_utf8);
    try std.testing.expect(std.mem.indexOf(u8, plain_utf8, "placement") == null);

    const xml = try buildToastXml(alloc, .{
        .title = "T",
        .body = "B",
        .attribution = "Tab 2: <a & \"b\">",
    }, .info);
    defer alloc.free(xml);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, xml);
    defer alloc.free(utf8);
    // The attribution is the last text of the binding, after the body.
    try std.testing.expect(std.mem.endsWith(
        u8,
        utf8,
        "<text>T</text><text>B</text>" ++
            "<text placement=\"attribution\">Tab 2: &lt;a &amp; &quot;b&quot;&gt;</text>" ++
            "</binding></visual></toast>",
    ));

    // A toast with nothing but a title and its tab has no empty body line.
    const untitled = try buildToastXml(alloc, .{ .title = "T", .body = "", .attribution = "Tab 1: x" }, .info);
    defer alloc.free(untitled);
    const untitled_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, untitled);
    defer alloc.free(untitled_utf8);
    try std.testing.expect(std.mem.indexOf(u8, untitled_utf8, "<text>T</text><text placement=\"attribution\">Tab 1: x</text>") != null);
}

test "WinrtToast GUID sizes are 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IInspectable)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IToastNotificationManagerStatics)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IToastNotificationFactory)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IXmlDocument)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(IID_IXmlDocumentIO)));
}

/// The 0-based vtable slot of `field`: three IUnknown and three IInspectable
/// methods come first.
fn vtblSlot(comptime Vtbl: type, comptime field: []const u8) usize {
    return @offsetOf(Vtbl, field) / @sizeOf(usize);
}

test "WinrtToast toast history and tag vtables follow the SDK slot order" {
    // Windows SDK 10.0.28000.0, winrt/windows.ui.notifications.h. The third
    // method of IToastNotificationManagerStatics is GetTemplateContent;
    // `get_History` is the only method of IToastNotificationManagerStatics2.
    try std.testing.expect(@hasField(IToastNotificationManagerStaticsVtbl, "GetTemplateContent"));
    try std.testing.expect(!@hasField(IToastNotificationManagerStaticsVtbl, "get_History"));
    try std.testing.expectEqual(@as(usize, 6), vtblSlot(IToastNotificationManagerStaticsVtbl, "CreateToastNotifier"));
    try std.testing.expectEqual(@as(usize, 7), vtblSlot(IToastNotificationManagerStaticsVtbl, "CreateToastNotifierWithId"));
    if (comptime @hasField(IToastNotificationManagerStaticsVtbl, "GetTemplateContent")) {
        try std.testing.expectEqual(@as(usize, 8), vtblSlot(IToastNotificationManagerStaticsVtbl, "GetTemplateContent"));
    }
    try std.testing.expectEqual(@as(usize, 9), @sizeOf(IToastNotificationManagerStaticsVtbl) / @sizeOf(usize));

    try std.testing.expectEqual(@as(usize, 6), vtblSlot(IToastNotificationManagerStatics2Vtbl, "get_History"));
    try std.testing.expectEqual(@as(usize, 7), @sizeOf(IToastNotificationManagerStatics2Vtbl) / @sizeOf(usize));

    inline for (.{ "put_Tag", "get_Tag", "put_Group", "get_Group", "put_SuppressPopup", "get_SuppressPopup" }, 6..) |name, slot| {
        try std.testing.expectEqual(@as(usize, slot), vtblSlot(IToastNotification2Vtbl, name));
    }
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(IToastNotification2Vtbl) / @sizeOf(usize));

    inline for (.{
        "RemoveGroup",
        "RemoveGroupWithId",
        "RemoveGroupedTagWithId",
        "RemoveGroupedTag",
        "Remove",
        "Clear",
        "ClearWithId",
    }, 6..) |name, slot| {
        try std.testing.expectEqual(@as(usize, slot), vtblSlot(IToastNotificationHistoryVtbl, name));
    }
    try std.testing.expectEqual(@as(usize, 13), @sizeOf(IToastNotificationHistoryVtbl) / @sizeOf(usize));
}

test "WinrtToast toast history and tag IIDs match the SDK" {
    const expected = [_]struct { iid: GUID, value: GUID }{
        .{ .iid = IID_IToastNotificationManagerStatics2, .value = .{
            .Data1 = 0x7ab93c52,
            .Data2 = 0x0e48,
            .Data3 = 0x4750,
            .Data4 = .{ 0xba, 0x9d, 0x1a, 0x41, 0x13, 0x98, 0x18, 0x47 },
        } },
        .{ .iid = IID_IToastNotification2, .value = .{
            .Data1 = 0x9dfb9fd1,
            .Data2 = 0x143a,
            .Data3 = 0x490e,
            .Data4 = .{ 0x90, 0xbf, 0xb9, 0xfb, 0xa7, 0x13, 0x2d, 0xe7 },
        } },
        .{ .iid = IID_IToastNotificationHistory, .value = .{
            .Data1 = 0x5caddc63,
            .Data2 = 0x01d3,
            .Data3 = 0x4c97,
            .Data4 = .{ 0x98, 0x6f, 0x05, 0x33, 0x48, 0x3f, 0xee, 0x14 },
        } },
    };
    for (expected) |pair| try std.testing.expect(iidEqual(&pair.iid, &pair.value));
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
