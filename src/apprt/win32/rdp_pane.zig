//! A Remote Desktop session inside a pane. A profile whose command line is
//! `mstsc.exe /v:<server>[:<port>]` (what the Terminals import writes for an
//! RDP connection) does not start mstsc.exe: its pane runs a placeholder
//! shell, and the Remote Desktop ActiveX control (`mstscax.dll`, hosted by
//! the system `atl.dll`'s `AtlAxWin` window class) covers the pane as its
//! child window. Tabs, splits, undo, close confirmation and session restore
//! keep working, because the pane is still a terminal pane underneath.
//!
//! When the session ends (the remote side logs off, the connection fails or
//! drops), the control goes and the placeholder shell shows, saying so.
//!
//! The password comes from the Windows Credential Manager
//! (`profile_credentials.zig`) and is handed to the control through
//! `IMsTscNonScriptable::put_ClearTextPassword`. Nothing here logs a server,
//! a user name or a password.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const terminals_import = @import("terminals_import.zig");
const profile_credentials = @import("profile_credentials.zig");

const BOOL = win32_types.BOOL;
const GUID = win32_types.GUID;
const HINSTANCE = win32_types.HINSTANCE;
const HRESULT = win32_types.HRESULT;
const HWND = win32_types.HWND;
const LPCWSTR = win32_types.LPCWSTR;
const RECT = win32_types.RECT;
const UINT = win32_types.UINT;

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.win32_rdp);

/// What the pane connects to: a profile's `mstsc.exe /v:` command line, read
/// back (`terminals_import.parseCommand`).
pub const Target = terminals_import.Connection;

/// The RDP target of a launch's command line, or null when it is not an
/// `mstsc.exe /v:` one.
pub fn targetOf(command_line: []const u8) ?Target {
    const conn = terminals_import.parseCommand(command_line) orelse return null;
    if (conn.protocol != .rdp) return null;
    return conn;
}

/// What an RDP pane runs instead of mstsc.exe: a shell that says what to do
/// once the session is over and then waits, reading no keys (`timeout
/// /nobreak`), so what is typed while noctty has the keyboard goes nowhere.
pub const placeholder_argv = [_][:0]const u8{
    "cmd.exe",
    "/d",
    "/q",
    "/c",
    "echo Remote Desktop session. When it ends, close this tab (Ctrl+Shift+W) or open the profile again.& timeout /t -1 /nobreak >nul",
};

// --- COM ----------------------------------------------------------------

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
    Release: *const fn (*IUnknown) callconv(.winapi) u32,
};
const IUnknown = extern struct { vtbl: *const IUnknownVtbl };

const DISPPARAMS = extern struct {
    rgvarg: ?[*]VARIANT = null,
    rgdispidNamedArgs: ?[*]i32 = null,
    cArgs: u32 = 0,
    cNamedArgs: u32 = 0,
};

const IDispatchVtbl = extern struct {
    QueryInterface: *const fn (*IDispatch, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDispatch) callconv(.winapi) u32,
    Release: *const fn (*IDispatch) callconv(.winapi) u32,
    GetTypeInfoCount: *const anyopaque,
    GetTypeInfo: *const anyopaque,
    GetIDsOfNames: *const fn (*IDispatch, *const GUID, [*]const [*:0]const u16, u32, u32, [*]i32) callconv(.winapi) HRESULT,
    Invoke: *const fn (*IDispatch, i32, *const GUID, u32, u16, *DISPPARAMS, ?*VARIANT, ?*anyopaque, ?*u32) callconv(.winapi) HRESULT,
};
const IDispatch = extern struct { vtbl: *const IDispatchVtbl };

/// IMsTscNonScriptable: IUnknown, then put_ClearTextPassword first.
const INonScriptableVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*INonScriptable) callconv(.winapi) u32,
    put_ClearTextPassword: *const fn (*INonScriptable, ?[*:0]const u16) callconv(.winapi) HRESULT,
};
const INonScriptable = extern struct { vtbl: *const INonScriptableVtbl };

/// oaidl.h's VARIANT: 16 bytes on 32-bit targets, 24 on 64-bit ones.
const VARIANT = extern struct {
    vt: u16 = 0,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    data: extern union {
        lVal: i32,
        iVal: i16,
        boolVal: i16,
        bstrVal: ?[*:0]u16,
        pdispVal: ?*IDispatch,
        record: [2]usize,
    } = .{ .record = .{ 0, 0 } },
};

const VT_EMPTY: u16 = 0;
const VT_I2: u16 = 2;
const VT_I4: u16 = 3;
const VT_BSTR: u16 = 8;
const VT_DISPATCH: u16 = 9;
const VT_BOOL: u16 = 11;
const DISPATCH_METHOD: u16 = 1;
const DISPATCH_PROPERTYGET: u16 = 2;
const DISPATCH_PROPERTYPUT: u16 = 4;
const DISPID_PROPERTYPUT: i32 = -3;
const LOCALE_USER_DEFAULT: u32 = 0x0400;

const IID_NULL: GUID = std.mem.zeroes(GUID);
const IID_IDispatch: GUID = .{ .Data1 = 0x00020400, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IMsTscNonScriptable: GUID = .{ .Data1 = 0xC1E6743A, .Data2 = 0x41C1, .Data3 = 0x4A74, .Data4 = .{ 0x83, 0x2A, 0x0D, 0xD0, 0x6C, 0x1C, 0x7A, 0x0E } };

/// The newest Remote Desktop clients first (`MsTscAx.MsTscAx.<n>`, the
/// not-safe-for-scripting classes, which take a password); the
/// version-independent ProgID last.
const control_names = [_][:0]const u16{
    L("MsTscAx.MsTscAx.13"),
    L("MsTscAx.MsTscAx.12"),
    L("MsTscAx.MsTscAx.11"),
    L("MsTscAx.MsTscAx.10"),
    L("MsTscAx.MsTscAx"),
};

extern "oleaut32" fn SysAllocString(text: ?[*:0]const u16) callconv(.winapi) ?[*:0]u16;
extern "oleaut32" fn SysFreeString(text: ?[*:0]u16) callconv(.winapi) void;
extern "oleaut32" fn VariantClear(v: *VARIANT) callconv(.winapi) HRESULT;
extern "kernel32" fn LoadLibraryW(name: LPCWSTR) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn GetProcAddress(module: HINSTANCE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
extern "user32" fn CreateWindowExW(ex: u32, class: LPCWSTR, name: LPCWSTR, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, inst: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn MoveWindow(hwnd: HWND, x: i32, y: i32, w: i32, h: i32, repaint: BOOL) callconv(.winapi) BOOL;
extern "user32" fn SetFocus(hwnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: u32, proc: ?*const fn (?HWND, UINT, usize, u32) callconv(.winapi) void) callconv(.winapi) usize;
extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(.winapi) BOOL;
extern "user32" fn SetPropW(hwnd: HWND, name: LPCWSTR, data: ?*anyopaque) callconv(.winapi) BOOL;
extern "user32" fn GetPropW(hwnd: HWND, name: LPCWSTR) callconv(.winapi) ?*anyopaque;
extern "user32" fn RemovePropW(hwnd: HWND, name: LPCWSTR) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: isize) callconv(.winapi) isize;

const AtlAxWinInitFn = *const fn () callconv(.winapi) BOOL;
const AtlAxGetControlFn = *const fn (HWND, *?*IUnknown) callconv(.winapi) HRESULT;

const Atl = struct { get_control: AtlAxGetControlFn };
var atl: ?Atl = null;

fn loadAtl() ?Atl {
    if (atl) |loaded| return loaded;
    const module = LoadLibraryW(L("atl.dll")) orelse return null;
    const init: AtlAxWinInitFn = @ptrCast(GetProcAddress(module, "AtlAxWinInit") orelse return null);
    const get_control: AtlAxGetControlFn = @ptrCast(GetProcAddress(module, "AtlAxGetControl") orelse return null);
    if (init() == 0) return null;
    atl = .{ .get_control = get_control };
    return atl;
}

fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

fn dispid(disp: *IDispatch, name: [*:0]const u16) ?i32 {
    var names = [_][*:0]const u16{name};
    var id: [1]i32 = .{0};
    if (!succeeded(disp.vtbl.GetIDsOfNames(disp, &IID_NULL, &names, 1, LOCALE_USER_DEFAULT, &id))) return null;
    return id[0];
}

fn put(disp: *IDispatch, name: [*:0]const u16, value: *VARIANT) bool {
    const id = dispid(disp, name) orelse return false;
    var named = [_]i32{DISPID_PROPERTYPUT};
    var params: DISPPARAMS = .{ .rgvarg = @ptrCast(value), .rgdispidNamedArgs = &named, .cArgs = 1, .cNamedArgs = 1 };
    return succeeded(disp.vtbl.Invoke(disp, id, &IID_NULL, LOCALE_USER_DEFAULT, DISPATCH_PROPERTYPUT, &params, null, null, null));
}

fn putI4(disp: *IDispatch, name: [*:0]const u16, value: i32) bool {
    var v: VARIANT = .{ .vt = VT_I4, .data = .{ .lVal = value } };
    return put(disp, name, &v);
}

fn putBool(disp: *IDispatch, name: [*:0]const u16, value: bool) bool {
    var v: VARIANT = .{ .vt = VT_BOOL, .data = .{ .boolVal = if (value) -1 else 0 } };
    return put(disp, name, &v);
}

fn putText(disp: *IDispatch, name: [*:0]const u16, alloc: Allocator, text: []const u8) bool {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return false;
    defer alloc.free(wide);
    const bstr = SysAllocString(wide.ptr) orelse return false;
    var v: VARIANT = .{ .vt = VT_BSTR, .data = .{ .bstrVal = bstr } };
    defer _ = VariantClear(&v);
    return put(disp, name, &v);
}

fn get(disp: *IDispatch, name: [*:0]const u16) ?VARIANT {
    const id = dispid(disp, name) orelse return null;
    var params: DISPPARAMS = .{};
    var result: VARIANT = .{};
    if (!succeeded(disp.vtbl.Invoke(disp, id, &IID_NULL, LOCALE_USER_DEFAULT, DISPATCH_PROPERTYGET, &params, &result, null, null))) return null;
    return result;
}

fn getDispatch(disp: *IDispatch, name: [*:0]const u16) ?*IDispatch {
    var v = get(disp, name) orelse return null;
    if (v.vt != VT_DISPATCH) {
        _ = VariantClear(&v);
        return null;
    }
    return v.data.pdispVal; // the reference is the caller's now
}

fn call(disp: *IDispatch, name: [*:0]const u16) bool {
    const id = dispid(disp, name) orelse return false;
    var params: DISPPARAMS = .{};
    return succeeded(disp.vtbl.Invoke(disp, id, &IID_NULL, LOCALE_USER_DEFAULT, DISPATCH_METHOD, &params, null, null, null));
}

// --- The pane -----------------------------------------------------------

/// How the remote desktop fits the pane (`rdp-scaling`).
pub const Scaling = enum { proportional, fill };

/// Where the control goes in a `width` x `height` pane showing a
/// `desk_w` x `desk_h` desktop: the whole pane (`fill`), or the largest
/// rectangle of the desktop's proportions, centred (`proportional`).
pub fn fitRect(scaling: Scaling, width: i32, height: i32, desk_w: i32, desk_h: i32) RECT {
    const w = @max(1, width);
    const h = @max(1, height);
    if (scaling == .fill or desk_w <= 0 or desk_h <= 0) return .{ .left = 0, .top = 0, .right = w, .bottom = h };
    // Compare w/h with desk_w/desk_h without rounding.
    const wide = @as(i64, w) * desk_h > @as(i64, h) * desk_w;
    const fit_w: i32 = if (wide) @intCast(@divTrunc(@as(i64, h) * desk_w, desk_h)) else w;
    const fit_h: i32 = if (wide) h else @intCast(@divTrunc(@as(i64, w) * desk_h, desk_w));
    const x = @divTrunc(w - fit_w, 2);
    const y = @divTrunc(h - fit_h, 2);
    return .{ .left = x, .top = y, .right = x + @max(1, fit_w), .bottom = y + @max(1, fit_h) };
}

/// What the pane tells its surface.
pub const Events = struct {
    ctx: *anyopaque,
    /// The session is over and the control has gone.
    ended: *const fn (ctx: *anyopaque) void,
    /// Ctrl+Alt+Home: the keyboard goes back to noctty.
    released: *const fn (ctx: *anyopaque) void,
    /// The session connected: the pane may say how to leave it.
    connected: *const fn (ctx: *anyopaque) void,
};

/// What the pane signs in with.
pub const Login = struct {
    /// The profile the credentials are kept for (`profile_credentials`),
    /// when the pane's command line is one profile's.
    profile_id: ?[]const u8 = null,
    user: []const u8 = "",
    /// Null when none is kept: the pane asks first.
    password: ?[]const u8 = null,
};

pub const Options = struct {
    scaling: Scaling = .proportional,
    /// Connect to a server whose identity cannot be checked without asking
    /// (`rdp-trust-certificates`).
    trust_certificates: bool = false,
};

pub const Pane = struct {
    alloc: Allocator,
    hwnd: HWND,
    control: *IDispatch,
    unknown: *IUnknown,
    events: Events,
    options: Options,
    /// Owned copies of the login, the password zeroed when freed.
    profile_id: ?[]u8 = null,
    user: []u8 = &.{},
    password: ?[]u8 = null,
    started: bool = false,
    /// Timer ticks since `Connect`.
    ticks: u32 = 0,
    /// The control reported a connection (or one under way) at least once.
    seen_connecting: bool = false,
    /// It reported a full connection, and the surface was told.
    told_connected: bool = false,
    /// The remote desktop's resolution, fixed when it connects.
    desk_w: i32,
    desk_h: i32,

    const prop_name = L("noctty.rdp_pane");
    const poll_timer: usize = 0x5244; // "RD"
    const start_timer: usize = 0x5253; // "RS"
    const GWL_STYLE: i32 = -16;

    /// Cover `parent`'s client area (`width` x `height`) with the Remote
    /// Desktop control for `target`. It connects from the message loop
    /// (`start`), after asking for the credentials when none are kept. Null
    /// when the control cannot be made (no atl.dll or no Remote Desktop
    /// client); the pane then shows its placeholder shell.
    pub fn create(alloc: Allocator, parent: HWND, target: Target, login: Login, width: i32, height: i32, options: Options, events: Events) ?*Pane {
        const loaded = loadAtl() orelse {
            log.warn("rdp pane: atl.dll could not host the control", .{});
            return null;
        };
        // The terminal's renderer must not paint over the control.
        const WS_CLIPCHILDREN: isize = 0x02000000;
        _ = SetWindowLongPtrW(parent, GWL_STYLE, GetWindowLongPtrW(parent, GWL_STYLE) | WS_CLIPCHILDREN);

        const WS_CHILD: u32 = 0x40000000;
        const WS_VISIBLE: u32 = 0x10000000;
        const WS_CLIPSIBLINGS: u32 = 0x04000000;
        const style = WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | @as(u32, @intCast(WS_CLIPCHILDREN));
        var hwnd: ?HWND = null;
        var unknown: ?*IUnknown = null;
        for (control_names) |name| {
            const made = CreateWindowExW(0, L("AtlAxWin"), name.ptr, style, 0, 0, @max(1, width), @max(1, height), parent, null, GetModuleHandleW(null), null) orelse continue;
            var unk: ?*IUnknown = null;
            if (succeeded(loaded.get_control(made, &unk)) and unk != null) {
                hwnd = made;
                unknown = unk;
                break;
            }
            _ = DestroyWindow(made);
        }
        const window = hwnd orelse {
            log.warn("rdp pane: no Remote Desktop control could be made", .{});
            return null;
        };
        const unk = unknown.?;
        var disp_raw: ?*anyopaque = null;
        if (!succeeded(unk.vtbl.QueryInterface(unk, &IID_IDispatch, &disp_raw)) or disp_raw == null) {
            _ = unk.vtbl.Release(unk);
            _ = DestroyWindow(window);
            return null;
        }
        const disp: *IDispatch = @ptrCast(@alignCast(disp_raw.?));

        const self = alloc.create(Pane) catch {
            _ = disp.vtbl.Release(disp);
            _ = unk.vtbl.Release(unk);
            _ = DestroyWindow(window);
            return null;
        };
        const desk_w = std.math.clamp(width, 200, 8192);
        const desk_h = std.math.clamp(height, 200, 8192);
        self.* = .{
            .alloc = alloc,
            .hwnd = window,
            .control = disp,
            .unknown = unk,
            .events = events,
            .options = options,
            .desk_w = desk_w,
            .desk_h = desk_h,
        };
        self.profile_id = if (login.profile_id) |id| alloc.dupe(u8, id) catch null else null;
        self.user = alloc.dupe(u8, login.user) catch &.{};
        self.password = if (login.password) |text| alloc.dupe(u8, text) catch null else null;

        _ = putText(disp, L("Server"), alloc, target.server);
        _ = putI4(disp, L("DesktopWidth"), desk_w);
        _ = putI4(disp, L("DesktopHeight"), desk_h);
        _ = putI4(disp, L("ColorDepth"), 32);
        const advanced = getDispatch(disp, L("AdvancedSettings9")) orelse getDispatch(disp, L("AdvancedSettings2"));
        if (advanced) |adv| {
            defer _ = adv.vtbl.Release(adv);
            _ = putI4(adv, L("RDPPort"), target.port);
            _ = putBool(adv, L("SmartSizing"), true);
            _ = putBool(adv, L("EnableCredSspSupport"), true);
            _ = putBool(adv, L("RedirectClipboard"), true);
            // 0: connect without asking about a server whose identity
            // cannot be checked. 2: warn and let the person decide, as
            // mstsc.exe does.
            _ = putI4(adv, L("AuthenticationLevel"), if (options.trust_certificates) 0 else 2);
            // Keys go to the remote desktop only while it has the focus,
            // so Ctrl+Alt+Home can give them back.
            _ = putI4(adv, L("KeyboardHookMode"), 0);
        }

        _ = SetPropW(window, prop_name, self);
        // Connect once the tab is made: the credential prompt is modal.
        _ = SetTimer(window, start_timer, 50, &startTick);
        return self;
    }

    fn setPassword(self: *Pane, text: []const u8) void {
        var raw: ?*anyopaque = null;
        if (!succeeded(self.unknown.vtbl.QueryInterface(self.unknown, &IID_IMsTscNonScriptable, &raw)) or raw == null) return;
        const ns: *INonScriptable = @ptrCast(@alignCast(raw.?));
        defer _ = ns.vtbl.Release(ns);
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, text) catch return;
        defer {
            @memset(wide, 0);
            self.alloc.free(wide);
        }
        const bstr = SysAllocString(wide.ptr) orelse return;
        defer {
            @memset(std.mem.span(bstr), 0);
            SysFreeString(bstr);
        }
        _ = ns.vtbl.put_ClearTextPassword(ns, bstr);
    }

    fn startTick(hwnd: ?HWND, _: UINT, _: usize, _: u32) callconv(.winapi) void {
        const window = hwnd orelse return;
        _ = KillTimer(window, start_timer);
        const raw = GetPropW(window, prop_name) orelse return;
        const self: *Pane = @ptrCast(@alignCast(raw));
        self.start();
    }

    /// Sign in and connect: with the kept credentials, or with the ones the
    /// person types into Windows' credential prompt, kept when they check
    /// "Remember".
    fn start(self: *Pane) void {
        if (self.started) return;
        self.started = true;
        if (self.password == null) self.askCredentials();
        if (self.user.len != 0) _ = putText(self.control, L("UserName"), self.alloc, self.user);
        if (self.password) |text| if (text.len != 0) self.setPassword(text);
        if (!call(self.control, L("Connect"))) log.warn("rdp pane: Connect failed", .{});
        _ = SetTimer(self.hwnd, poll_timer, 1000, &tick);
    }

    fn askCredentials(self: *Pane) void {
        const typed = promptCredentials(self.alloc, self.hwnd, self.user) orelse return;
        self.alloc.free(self.user);
        self.user = typed.user;
        self.password = typed.password;
        if (typed.save) if (self.profile_id) |id| {
            profile_credentials.store(id, typed.user, typed.password) catch
                log.warn("rdp pane: the credentials could not be kept", .{});
        };
    }

    /// The pane's new size.
    pub fn resize(self: *Pane, width: i32, height: i32) void {
        const rect = fitRect(self.options.scaling, width, height, self.desk_w, self.desk_h);
        _ = MoveWindow(self.hwnd, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, 1);
    }

    pub fn focus(self: *Pane) void {
        _ = SetFocus(self.hwnd);
    }

    /// End the session and the control (the pane goes, or the session ended).
    pub fn destroy(self: *Pane) void {
        _ = KillTimer(self.hwnd, poll_timer);
        _ = KillTimer(self.hwnd, start_timer);
        _ = RemovePropW(self.hwnd, prop_name);
        if (connectedState(self.control) != 0) _ = call(self.control, L("Disconnect"));
        _ = self.control.vtbl.Release(self.control);
        _ = self.unknown.vtbl.Release(self.unknown);
        _ = DestroyWindow(self.hwnd);
        if (self.password) |text| {
            @memset(text, 0);
            self.alloc.free(text);
        }
        self.alloc.free(self.user);
        if (self.profile_id) |id| self.alloc.free(id);
        self.alloc.destroy(self);
    }

    /// The control's `Connected`: 0 not connected, 1 connected, 2 connecting.
    fn connectedState(disp: *IDispatch) i32 {
        var v = get(disp, L("Connected")) orelse return 0;
        defer _ = VariantClear(&v);
        return switch (v.vt) {
            VT_I2 => v.data.iVal,
            VT_I4 => v.data.lVal,
            else => 0,
        };
    }

    fn tick(hwnd: ?HWND, _: UINT, _: usize, _: u32) callconv(.winapi) void {
        const window = hwnd orelse return;
        const raw = GetPropW(window, prop_name) orelse return;
        const self: *Pane = @ptrCast(@alignCast(raw));
        self.ticks +|= 1;
        const state = connectedState(self.control);
        if (state != 0) {
            self.seen_connecting = true;
            if (state == 1 and !self.told_connected) {
                self.told_connected = true;
                self.events.connected(self.events.ctx);
            }
            return;
        }
        // Not connected: over once it was under way, or when it never
        // started (a bad server name fails before Connect returns).
        if (!self.seen_connecting and self.ticks < 5) return;
        const events = self.events;
        self.destroy();
        events.ended(events.ctx);
    }

    /// The pane whose control holds `hwnd` (the control's own windows are
    /// its descendants), if any.
    fn owning(hwnd: ?HWND) ?*Pane {
        var at = hwnd;
        var depth: usize = 0;
        while (at) |window| : (depth += 1) {
            if (depth > 16) return null;
            if (GetPropW(window, prop_name)) |raw| return @ptrCast(@alignCast(raw));
            at = GetParent(window);
        }
        return null;
    }
};

/// Ctrl+Alt+Home pressed in a Remote Desktop pane, as the loop reads it
/// before translation: the keyboard goes back to noctty (`Events.released`),
/// and the key reaches neither the remote desktop nor a terminal. Returns
/// whether it took the message.
pub fn takeReleaseKey(hwnd: ?HWND, message: UINT, wparam: usize) bool {
    const WM_KEYDOWN: UINT = 0x0100;
    const WM_SYSKEYDOWN: UINT = 0x0104;
    const VK_HOME: usize = 0x24;
    if (message != WM_KEYDOWN and message != WM_SYSKEYDOWN) return false;
    if (wparam != VK_HOME) return false;
    const VK_CONTROL: i32 = 0x11;
    const VK_MENU: i32 = 0x12;
    if (GetKeyState(VK_CONTROL) >= 0 or GetKeyState(VK_MENU) >= 0) return false;
    const pane = Pane.owning(hwnd) orelse return false;
    pane.events.released(pane.events.ctx);
    return true;
}

// --- Windows' credential prompt -----------------------------------------

const CREDUI_INFOW = extern struct {
    cbSize: u32,
    hwndParent: ?HWND,
    pszMessageText: ?LPCWSTR,
    pszCaptionText: ?LPCWSTR,
    hbmBanner: ?*anyopaque,
};
const CREDUIWIN_GENERIC: u32 = 0x1;
const CREDUIWIN_CHECKBOX: u32 = 0x2;
const CRED_PACK_GENERIC_CREDENTIALS: u32 = 0x4;

extern "credui" fn CredUIPromptForWindowsCredentialsW(info: *const CREDUI_INFOW, auth_error: u32, package: *u32, in_buf: ?*const anyopaque, in_size: u32, out_buf: *?*anyopaque, out_size: *u32, save: *BOOL, flags: u32) callconv(.winapi) u32;
extern "credui" fn CredPackAuthenticationBufferW(flags: u32, user: LPCWSTR, password: LPCWSTR, buf: ?[*]u8, size: *u32) callconv(.winapi) BOOL;
extern "credui" fn CredUnPackAuthenticationBufferW(flags: u32, buf: *const anyopaque, size: u32, user: ?[*]u16, user_len: *u32, domain: ?[*]u16, domain_len: *u32, password: ?[*]u16, password_len: *u32) callconv(.winapi) BOOL;
extern "ole32" fn CoTaskMemFree(ptr: ?*anyopaque) callconv(.winapi) void;
extern "user32" fn GetParent(hwnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetKeyState(vk: i32) callconv(.winapi) i16;

const Typed = struct { user: []u8, password: []u8, save: bool };

/// Windows' own credential prompt, the user name filled in with `user`,
/// with "Remember my credentials". Null when cancelled.
fn promptCredentials(alloc: Allocator, owner: HWND, user: []const u8) ?Typed {
    var in_buf: ?[]u8 = null;
    defer if (in_buf) |buf| {
        @memset(buf, 0);
        alloc.free(buf);
    };
    if (user.len != 0) pack: {
        const user_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, user) catch break :pack;
        defer alloc.free(user_w);
        var size: u32 = 0;
        _ = CredPackAuthenticationBufferW(CRED_PACK_GENERIC_CREDENTIALS, user_w.ptr, L(""), null, &size);
        if (size == 0) break :pack;
        const buf = alloc.alloc(u8, size) catch break :pack;
        if (CredPackAuthenticationBufferW(CRED_PACK_GENERIC_CREDENTIALS, user_w.ptr, L(""), buf.ptr, &size) == 0) {
            alloc.free(buf);
            break :pack;
        }
        in_buf = buf[0..size];
    }
    const info: CREDUI_INFOW = .{
        .cbSize = @sizeOf(CREDUI_INFOW),
        .hwndParent = owner,
        .pszMessageText = L("Sign in to the remote computer. Check Remember to keep the credentials in the Windows Credential Manager for this profile."),
        .pszCaptionText = L("noctty Remote Desktop"),
        .hbmBanner = null,
    };
    var package: u32 = 0;
    var out: ?*anyopaque = null;
    var out_size: u32 = 0;
    var save: BOOL = 0;
    const in_ptr: ?*const anyopaque = if (in_buf) |buf| buf.ptr else null;
    const in_len: u32 = if (in_buf) |buf| @intCast(buf.len) else 0;
    if (CredUIPromptForWindowsCredentialsW(&info, 0, &package, in_ptr, in_len, &out, &out_size, &save, CREDUIWIN_GENERIC | CREDUIWIN_CHECKBOX) != 0) return null;
    const out_buf = out orelse return null;
    defer {
        @memset(@as([*]u8, @ptrCast(out_buf))[0..out_size], 0);
        CoTaskMemFree(out_buf);
    }
    var user_w: [514]u16 = undefined;
    var domain_w: [256]u16 = undefined;
    var password_w: [514]u16 = undefined;
    defer @memset(&password_w, 0);
    var user_len: u32 = user_w.len;
    var domain_len: u32 = domain_w.len;
    var password_len: u32 = password_w.len;
    if (CredUnPackAuthenticationBufferW(0, out_buf, out_size, &user_w, &user_len, &domain_w, &domain_len, &password_w, &password_len) == 0) return null;
    // The lengths count the terminating NUL.
    const user_text = std.unicode.utf16LeToUtf8Alloc(alloc, user_w[0..@min(user_len, user_w.len) -| 1]) catch return null;
    const password_text = std.unicode.utf16LeToUtf8Alloc(alloc, password_w[0..@min(password_len, password_w.len) -| 1]) catch {
        alloc.free(user_text);
        return null;
    };
    return .{ .user = user_text, .password = password_text, .save = save != 0 };
}

test "rdp pane: targetOf takes mstsc /v: command lines only" {
    const t = targetOf("mstsc.exe /v:38.210.212.220:5589").?;
    try std.testing.expectEqualStrings("38.210.212.220", t.server);
    try std.testing.expectEqual(@as(u16, 5589), t.port);
    try std.testing.expectEqual(@as(u16, 3389), targetOf("mstsc /v:srv").?.port);
    try std.testing.expect(targetOf("ssh host") == null);
    try std.testing.expect(targetOf("mstsc.exe") == null);
    try std.testing.expect(targetOf("pwsh.exe") == null);
}

test "rdp pane: fitRect fills, or keeps the desktop's proportions centred" {
    const fill = fitRect(.fill, 1000, 500, 800, 600);
    try std.testing.expectEqual(@as(i32, 1000), fill.right);
    try std.testing.expectEqual(@as(i32, 500), fill.bottom);
    // A wide pane: bars left and right.
    const wide = fitRect(.proportional, 1000, 600, 800, 600);
    try std.testing.expectEqual(@as(i32, 100), wide.left);
    try std.testing.expectEqual(@as(i32, 900), wide.right);
    try std.testing.expectEqual(@as(i32, 0), wide.top);
    // A tall pane: bars above and below.
    const tall = fitRect(.proportional, 800, 1000, 800, 600);
    try std.testing.expectEqual(@as(i32, 0), tall.left);
    try std.testing.expectEqual(@as(i32, 200), tall.top);
    try std.testing.expectEqual(@as(i32, 800), tall.bottom);
}

test "rdp pane: COM structs match the SDK" {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VARIANT));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(VARIANT, "data"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(DISPPARAMS));
}
