//! COM `IDropTarget` implementation for winghostty terminal surfaces.
//!
//! Wraps the payload-parsing logic in `win32_surface_drop.zig` behind the
//! standard OLE drag-drop COM interface so Explorer (and any other drag
//! source) can drop files, text, URLs, and HTML onto a terminal pane.
//!
//! Lifetime: caller-owned. The struct is stack- or field-embedded in the
//! surface; `init` / `deinit` are symmetric. `register` / `revoke` pair
//! around the HWND lifetime.
//!
//! Thread safety: all COM callbacks arrive on the thread that called
//! `RegisterDragDrop`, which MUST be the STA-initialised UI thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const drop = @import("win32_surface_drop.zig");
const ole_types = @import("win32_ole.zig");
const win32_types = @import("win32_types.zig");

const log = std.log.scoped(.win32_drop_target);

// ── Win32 type aliases ─────────────────────────────────────────────────

const HRESULT = ole_types.HRESULT;
const HWND = win32_types.HWND;
const GUID = ole_types.GUID;
const BOOL = win32_types.BOOL;
const DWORD = ole_types.DWORD;
const UINT = win32_types.UINT;
const ULONG = ole_types.ULONG;
const WORD = ole_types.WORD;

const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
const E_UNEXPECTED: HRESULT = @bitCast(@as(u32, 0x8000FFFF));

const DRAGDROP_E_ALREADYREGISTERED: HRESULT = @bitCast(@as(u32, 0x80040101));
const DRAGDROP_E_NOTREGISTERED: HRESULT = @bitCast(@as(u32, 0x80040100));
const CO_E_NOTINITIALIZED: HRESULT = @bitCast(@as(u32, 0x800401F0));

// Drop effects.
const DROPEFFECT_NONE: DWORD = 0;
const DROPEFFECT_COPY: DWORD = 1;

// Clipboard formats (well-known constants).
const CF_HDROP: WORD = 15;
const CF_UNICODETEXT: WORD = 13;

// MK_ key-state flags present in `grfKeyState`.
const MK_SHIFT: DWORD = 0x0004;
const MK_CONTROL: DWORD = 0x0008;
const MK_ALT: DWORD = 0x0020;

// TYMED flags.
const TYMED_HGLOBAL: DWORD = 1;

// DVASPECT.
const DVASPECT_CONTENT: DWORD = 1;

// DATADIR for EnumFormatEtc.
const DATADIR_GET: DWORD = 1;

// IIDs.
const IID_IUnknown = ole_types.IID_IUnknown;
const IID_IDropTarget = ole_types.IID_IDropTarget;
const IID_IEnumFORMATETC = ole_types.IID_IEnumFORMATETC;

// ── OLE shared types ───────────────────────────────────────────────────

const POINTL = win32_types.POINTL;
const FORMATETC = ole_types.FORMATETC;
const STGMEDIUM = ole_types.STGMEDIUM;
const IDataObject = ole_types.IDataObject;
const IEnumFORMATETC = ole_types.IEnumFORMATETC;

// ── IDropTarget v-table layout ─────────────────────────────────────────

const IDropTargetVtbl = extern struct {
    // IUnknown (3 slots)
    QueryInterface: *const fn (*IDropTargetObj, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDropTargetObj) callconv(.winapi) ULONG,
    Release: *const fn (*IDropTargetObj) callconv(.winapi) ULONG,
    // IDropTarget (4 slots)
    DragEnter: *const fn (*IDropTargetObj, *IDataObject, DWORD, POINTL, *DWORD) callconv(.winapi) HRESULT,
    DragOver: *const fn (*IDropTargetObj, DWORD, POINTL, *DWORD) callconv(.winapi) HRESULT,
    DragLeave: *const fn (*IDropTargetObj) callconv(.winapi) HRESULT,
    Drop: *const fn (*IDropTargetObj, *IDataObject, DWORD, POINTL, *DWORD) callconv(.winapi) HRESULT,
};

/// The COM object shape: v-table pointer first (COM layout invariant).
const IDropTargetObj = extern struct {
    vtbl: *const IDropTargetVtbl,
};

// Comptime layout assertion: 3 IUnknown + 4 IDropTarget = 7 fn-pointer slots.
comptime {
    const expected = 7 * @sizeOf(*anyopaque);
    if (@sizeOf(IDropTargetVtbl) != expected) {
        @compileError(std.fmt.comptimePrint(
            "IDropTargetVtbl size mismatch: got {d}, expected {d}",
            .{ @sizeOf(IDropTargetVtbl), expected },
        ));
    }
}

// ── Runtime-loaded functions ───────────────────────────────────────────

const Ole32Fns = struct {
    RegisterDragDrop: *const fn (HWND, *IDropTargetObj) callconv(.winapi) HRESULT = undefined,
    RevokeDragDrop: *const fn (HWND) callconv(.winapi) HRESULT = undefined,
    CoTaskMemFree: *const fn (?*anyopaque) callconv(.winapi) void = undefined,
    ReleaseStgMedium: *const fn (*STGMEDIUM) callconv(.winapi) void = undefined,
};

const Shell32Fns = struct {
    DragQueryFileW: *const fn (?*anyopaque, UINT, ?[*]u16, UINT) callconv(.winapi) UINT = undefined,
    DragFinish: *const fn (?*anyopaque) callconv(.winapi) void = undefined,
};

const Kernel32Fns = struct {
    GlobalLock: *const fn (?*anyopaque) callconv(.winapi) ?[*]u8 = undefined,
    GlobalUnlock: *const fn (?*anyopaque) callconv(.winapi) BOOL = undefined,
    GlobalSize: *const fn (?*anyopaque) callconv(.winapi) usize = undefined,
};

const User32Fns = struct {
    RegisterClipboardFormatW: *const fn ([*:0]const u16) callconv(.winapi) UINT = undefined,
};

var ole32_fns: ?Ole32Fns = null;
var shell32_fns: ?Shell32Fns = null;
var kernel32_fns: ?Kernel32Fns = null;
var user32_fns: ?User32Fns = null;

/// Registered format IDs (process-local, cached on first use).
var cf_html_id: UINT = 0;
var cf_shellurl_id: UINT = 0;

fn loadOle32() ?Ole32Fns {
    if (ole32_fns) |fns| return fns;
    const dll = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("ole32.dll")) orelse return null;
    var fns: Ole32Fns = .{};
    fns.RegisterDragDrop = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "RegisterDragDrop") orelse return null));
    fns.RevokeDragDrop = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "RevokeDragDrop") orelse return null));
    fns.CoTaskMemFree = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "CoTaskMemFree") orelse return null));
    fns.ReleaseStgMedium = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "ReleaseStgMedium") orelse return null));
    ole32_fns = fns;
    return fns;
}

fn loadShell32() ?Shell32Fns {
    if (shell32_fns) |fns| return fns;
    const dll = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("shell32.dll")) orelse return null;
    var fns: Shell32Fns = .{};
    fns.DragQueryFileW = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "DragQueryFileW") orelse return null));
    fns.DragFinish = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "DragFinish") orelse return null));
    shell32_fns = fns;
    return fns;
}

fn loadKernel32() ?Kernel32Fns {
    if (kernel32_fns) |fns| return fns;
    const dll = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse return null;
    var fns: Kernel32Fns = .{};
    fns.GlobalLock = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "GlobalLock") orelse return null));
    fns.GlobalUnlock = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "GlobalUnlock") orelse return null));
    fns.GlobalSize = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "GlobalSize") orelse return null));
    kernel32_fns = fns;
    return fns;
}

fn loadUser32() ?User32Fns {
    if (user32_fns) |fns| return fns;
    const dll = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse return null;
    var fns: User32Fns = .{};
    fns.RegisterClipboardFormatW = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "RegisterClipboardFormatW") orelse return null));
    user32_fns = fns;
    return fns;
}

fn ensureCustomFormats() void {
    if (cf_html_id != 0) return;
    const u32fns = loadUser32() orelse return;
    cf_html_id = u32fns.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("HTML Format"));
    cf_shellurl_id = u32fns.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("UniformResourceLocator"));
}

// ── DropTarget (public API) ────────────────────────────────────────────

pub const PayloadFn = *const fn (surface_ctx: *anyopaque, payload: []const u8) void;

pub const RegError = error{ RegisterFailed, OleNotInitialized, RuntimeMissing };

pub const DropTarget = struct {
    /// COM object header — MUST be first field so `&self == &self.obj`.
    obj: IDropTargetObj,
    refcount: std.atomic.Value(u32),
    alloc: Allocator,
    surface_ctx: *anyopaque,
    on_payload: PayloadFn,
    /// Cached from DragEnter: at least one accepted format was offered.
    has_accepted_format: bool,

    /// Singleton v-table shared by all instances.
    const vtbl: IDropTargetVtbl = .{
        .QueryInterface = DropTarget.QueryInterface,
        .AddRef = DropTarget.AddRef,
        .Release = DropTarget.Release,
        .DragEnter = DropTarget.DragEnter,
        .DragOver = DropTarget.DragOver,
        .DragLeave = DropTarget.DragLeave,
        .Drop = DropTarget.handleDrop,
    };

    pub fn init(alloc: Allocator, surface_ctx: *anyopaque, on_payload: PayloadFn) DropTarget {
        ensureCustomFormats();
        return .{
            .obj = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .surface_ctx = surface_ctx,
            .on_payload = on_payload,
            .has_accepted_format = false,
        };
    }

    pub fn register(self: *DropTarget, hwnd: HWND) RegError!void {
        const fns = loadOle32() orelse return error.RuntimeMissing;
        const hr = fns.RegisterDragDrop(hwnd, &self.obj);
        if (hr == S_OK or hr == DRAGDROP_E_ALREADYREGISTERED) return;
        if (hr == CO_E_NOTINITIALIZED) return error.OleNotInitialized;
        return error.RegisterFailed;
    }

    pub fn revoke(self: *DropTarget, hwnd: HWND) void {
        _ = self;
        const fns = loadOle32() orelse {
            log.warn("ole32 not loaded during RevokeDragDrop", .{});
            return;
        };
        const hr = fns.RevokeDragDrop(hwnd);
        if (hr != S_OK and hr != DRAGDROP_E_NOTREGISTERED) {
            log.warn("RevokeDragDrop failed: 0x{x}", .{@as(u32, @bitCast(hr))});
        }
    }

    pub fn deinit(self: *DropTarget) void {
        if (std.debug.runtime_safety) {
            const rc = self.refcount.load(.acquire);
            std.debug.assert(rc == 0 or rc == 1);
        }
    }

    fn fromObj(p: *IDropTargetObj) *DropTarget {
        return @fieldParentPtr("obj", p);
    }

    // ── IUnknown ────────────────────────────────────────────────────────

    fn QueryInterface(
        self_obj: *IDropTargetObj,
        iid: *const GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        out.* = null;
        if (iidEqual(iid, &IID_IUnknown) or iidEqual(iid, &IID_IDropTarget)) {
            out.* = @ptrCast(&self.obj);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    fn AddRef(self_obj: *IDropTargetObj) callconv(.winapi) ULONG {
        const self = fromObj(self_obj);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Release(self_obj: *IDropTargetObj) callconv(.winapi) ULONG {
        const self = fromObj(self_obj);
        const prev = self.refcount.fetchSub(1, .acq_rel);
        // Caller-owned lifetime: do NOT auto-free when refcount hits 0.
        return prev - 1;
    }

    // ── IDropTarget ─────────────────────────────────────────────────────

    fn DragEnter(
        self_obj: *IDropTargetObj,
        data_object: *IDataObject,
        _: DWORD, // grfKeyState
        _: POINTL,
        pdwEffect: *DWORD,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        self.has_accepted_format = probeFormats(data_object);
        pdwEffect.* = if (self.has_accepted_format) DROPEFFECT_COPY else DROPEFFECT_NONE;
        return S_OK;
    }

    fn DragOver(
        self_obj: *IDropTargetObj,
        _: DWORD,
        _: POINTL,
        pdwEffect: *DWORD,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        pdwEffect.* = if (self.has_accepted_format) DROPEFFECT_COPY else DROPEFFECT_NONE;
        return S_OK;
    }

    fn DragLeave(self_obj: *IDropTargetObj) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        self.has_accepted_format = false;
        return S_OK;
    }

    fn handleDrop(
        self_obj: *IDropTargetObj,
        data_object: *IDataObject,
        grfKeyState: DWORD,
        _: POINTL,
        pdwEffect: *DWORD,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        defer self.has_accepted_format = false;

        const mods = modifiersFromKeyState(grfKeyState);

        // Try formats in priority order.
        if (self.tryExtractHdrop(data_object, mods)) |payload| {
            defer self.alloc.free(payload);
            self.on_payload(self.surface_ctx, payload);
            pdwEffect.* = DROPEFFECT_COPY;
            return S_OK;
        }

        if (self.tryExtractUnicodeText(data_object, mods)) |payload| {
            defer self.alloc.free(payload);
            self.on_payload(self.surface_ctx, payload);
            pdwEffect.* = DROPEFFECT_COPY;
            return S_OK;
        }

        if (self.tryExtractHtml(data_object, mods)) |payload| {
            defer self.alloc.free(payload);
            self.on_payload(self.surface_ctx, payload);
            pdwEffect.* = DROPEFFECT_COPY;
            return S_OK;
        }

        if (self.tryExtractShellUrl(data_object)) |payload| {
            defer self.alloc.free(payload);
            self.on_payload(self.surface_ctx, payload);
            pdwEffect.* = DROPEFFECT_COPY;
            return S_OK;
        }

        pdwEffect.* = DROPEFFECT_NONE;
        return S_OK;
    }

    // ── Format extraction helpers ───────────────────────────────────────

    fn tryExtractHdrop(self: *DropTarget, data_object: *IDataObject, mods: drop.Modifiers) ?[]u8 {
        const sh32 = loadShell32() orelse return null;
        const k32 = loadKernel32() orelse return null;
        const ole = loadOle32() orelse return null;

        var fmt = FORMATETC{
            .cfFormat = CF_HDROP,
            .ptd = null,
            .dwAspect = DVASPECT_CONTENT,
            .lindex = -1,
            .tymed = TYMED_HGLOBAL,
        };
        var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

        if (data_object.vtbl.GetData(data_object, &fmt, &stg) != S_OK) return null;
        defer ole.ReleaseStgMedium(&stg);

        const hDrop = stg.u.hGlobal orelse return null;
        const file_count = sh32.DragQueryFileW(hDrop, 0xFFFFFFFF, null, 0);
        if (file_count == 0) return null;

        // Collect UTF-8 paths.
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (paths.items) |p| self.alloc.free(p);
            paths.deinit(self.alloc);
        }

        for (0..file_count) |i| {
            const idx: UINT = @intCast(i);
            const wchar_len = sh32.DragQueryFileW(hDrop, idx, null, 0);
            if (wchar_len == 0) continue;

            const buf = self.alloc.alloc(u16, wchar_len + 1) catch continue;
            defer self.alloc.free(buf);
            _ = sh32.DragQueryFileW(hDrop, idx, buf.ptr, wchar_len + 1);

            // Convert UTF-16 to UTF-8.
            const utf8 = std.unicode.utf16LeToUtf8Alloc(self.alloc, buf[0..wchar_len]) catch continue;
            paths.append(self.alloc, utf8) catch {
                self.alloc.free(utf8);
                continue;
            };
        }

        if (paths.items.len == 0) return null;

        // Use GlobalLock just to satisfy the borrow — already extracted via DragQueryFileW.
        _ = k32;

        return drop.formatFilePayload(self.alloc, paths.items, mods) catch null;
    }

    fn tryExtractUnicodeText(self: *DropTarget, data_object: *IDataObject, mods: drop.Modifiers) ?[]u8 {
        const k32 = loadKernel32() orelse return null;
        const ole = loadOle32() orelse return null;

        var fmt = FORMATETC{
            .cfFormat = CF_UNICODETEXT,
            .ptd = null,
            .dwAspect = DVASPECT_CONTENT,
            .lindex = -1,
            .tymed = TYMED_HGLOBAL,
        };
        var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

        if (data_object.vtbl.GetData(data_object, &fmt, &stg) != S_OK) return null;
        defer ole.ReleaseStgMedium(&stg);

        const hGlobal = stg.u.hGlobal orelse return null;
        const locked: [*]const u16 = @ptrCast(@alignCast(k32.GlobalLock(hGlobal) orelse return null));
        defer _ = k32.GlobalUnlock(hGlobal);

        // Find the null terminator or use GlobalSize.
        const byte_size = k32.GlobalSize(hGlobal);
        const max_u16 = byte_size / 2;
        var len: usize = 0;
        while (len < max_u16 and locked[len] != 0) : (len += 1) {}

        if (len == 0) return null;

        const utf8 = std.unicode.utf16LeToUtf8Alloc(self.alloc, locked[0..len]) catch return null;
        defer self.alloc.free(utf8);

        return drop.formatTextPayload(self.alloc, utf8, mods) catch null;
    }

    fn tryExtractHtml(self: *DropTarget, data_object: *IDataObject, mods: drop.Modifiers) ?[]u8 {
        if (cf_html_id == 0) return null;
        const k32 = loadKernel32() orelse return null;
        const ole = loadOle32() orelse return null;

        var fmt = FORMATETC{
            .cfFormat = @intCast(cf_html_id),
            .ptd = null,
            .dwAspect = DVASPECT_CONTENT,
            .lindex = -1,
            .tymed = TYMED_HGLOBAL,
        };
        var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

        if (data_object.vtbl.GetData(data_object, &fmt, &stg) != S_OK) return null;
        defer ole.ReleaseStgMedium(&stg);

        const hGlobal = stg.u.hGlobal orelse return null;
        const locked: [*]const u8 = @ptrCast(k32.GlobalLock(hGlobal) orelse return null);
        defer _ = k32.GlobalUnlock(hGlobal);

        const byte_size = k32.GlobalSize(hGlobal);
        if (byte_size == 0) return null;

        // CF_HTML is UTF-8 encoded with a header. Extract the fragment.
        const fragment = drop.extractHtmlFragment(locked[0..byte_size]);
        if (fragment.len == 0) return null;

        return drop.formatTextPayload(self.alloc, fragment, mods) catch null;
    }

    fn tryExtractShellUrl(self: *DropTarget, data_object: *IDataObject) ?[]u8 {
        if (cf_shellurl_id == 0) return null;
        const k32 = loadKernel32() orelse return null;
        const ole = loadOle32() orelse return null;

        var fmt = FORMATETC{
            .cfFormat = @intCast(cf_shellurl_id),
            .ptd = null,
            .dwAspect = DVASPECT_CONTENT,
            .lindex = -1,
            .tymed = TYMED_HGLOBAL,
        };
        var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

        if (data_object.vtbl.GetData(data_object, &fmt, &stg) != S_OK) return null;
        defer ole.ReleaseStgMedium(&stg);

        const hGlobal = stg.u.hGlobal orelse return null;
        const locked: [*]const u8 = @ptrCast(k32.GlobalLock(hGlobal) orelse return null);
        defer _ = k32.GlobalUnlock(hGlobal);

        const byte_size = k32.GlobalSize(hGlobal);
        if (byte_size == 0) return null;

        const url = drop.extractShellUrl(locked[0..byte_size]);
        if (url.len == 0) return null;

        const result = self.alloc.alloc(u8, url.len) catch return null;
        @memcpy(result, url);
        return result;
    }
};

// ── Helpers ────────────────────────────────────────────────────────────

fn iidEqual(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

pub fn modifiersFromKeyState(key_state: DWORD) drop.Modifiers {
    return .{
        .shift = (key_state & MK_SHIFT) != 0,
        .ctrl = (key_state & MK_CONTROL) != 0,
        .alt = (key_state & MK_ALT) != 0,
    };
}

/// Enumerate formats offered by the data object and check for any we accept.
/// Falls back to per-format `QueryGetData` probes when `EnumFormatEtc` is
/// unavailable — some `IDataObject` providers (older browsers, limited
/// test shells) return `E_NOTIMPL` from enumeration but still serve
/// `GetData` correctly. Without this fallback we'd reject otherwise-
/// valid drops as "no accepted formats".
fn probeFormats(data_object: *IDataObject) bool {
    ensureCustomFormats();

    var enumerator: ?*IEnumFORMATETC = null;
    if (data_object.vtbl.EnumFormatEtc(data_object, DATADIR_GET, &enumerator) == S_OK) {
        if (enumerator) |e| {
            defer _ = e.vtbl.Release(e);
            var fmt: FORMATETC = undefined;
            while (e.vtbl.Next(e, 1, @ptrCast(&fmt), null) == S_OK) {
                if (fmt.cfFormat == CF_HDROP) return true;
                if (fmt.cfFormat == CF_UNICODETEXT) return true;
                if (cf_html_id != 0 and fmt.cfFormat == @as(WORD, @intCast(cf_html_id))) return true;
                if (cf_shellurl_id != 0 and fmt.cfFormat == @as(WORD, @intCast(cf_shellurl_id))) return true;
            }
            return false;
        }
    }

    // Fallback: direct `QueryGetData` per candidate format. We just
    // need "yes, this provider will serve at least one of our formats";
    // no enumeration needed.
    return queryGetDataForFormat(data_object, CF_HDROP) or
        queryGetDataForFormat(data_object, CF_UNICODETEXT) or
        (cf_html_id != 0 and queryGetDataForFormat(data_object, @as(WORD, @intCast(cf_html_id)))) or
        (cf_shellurl_id != 0 and queryGetDataForFormat(data_object, @as(WORD, @intCast(cf_shellurl_id))));
}

fn queryGetDataForFormat(data_object: *IDataObject, cf: WORD) bool {
    const fmt: FORMATETC = .{
        .cfFormat = cf,
        .ptd = null,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
    return data_object.vtbl.QueryGetData(data_object, &fmt) == S_OK;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "DropTarget QueryInterface returns IDropTarget on the known IID" {
    var captured: []const u8 = &.{};
    _ = &captured;
    const noop = struct {
        fn cb(_: *anyopaque, _: []const u8) void {}
    }.cb;
    var dt = DropTarget.init(std.testing.allocator, @ptrFromInt(0x1), noop);

    var out: ?*anyopaque = null;
    const hr = DropTarget.QueryInterface(&dt.obj, &IID_IDropTarget, &out);
    try std.testing.expectEqual(S_OK, hr);
    try std.testing.expect(out != null);

    // QI added a ref — release it.
    _ = DropTarget.Release(&dt.obj);

    // Unknown IID must fail.
    const bogus = GUID.parse("{DEADBEEF-0000-0000-0000-000000000000}");
    var out2: ?*anyopaque = null;
    const hr2 = DropTarget.QueryInterface(&dt.obj, &bogus, &out2);
    try std.testing.expectEqual(E_NOINTERFACE, hr2);
    try std.testing.expect(out2 == null);

    // IID_IUnknown must also succeed.
    var out3: ?*anyopaque = null;
    const hr3 = DropTarget.QueryInterface(&dt.obj, &IID_IUnknown, &out3);
    try std.testing.expectEqual(S_OK, hr3);
    _ = DropTarget.Release(&dt.obj);
}

test "DropTarget AddRef/Release refcount is atomic" {
    const noop = struct {
        fn cb(_: *anyopaque, _: []const u8) void {}
    }.cb;
    var dt = DropTarget.init(std.testing.allocator, @ptrFromInt(0x1), noop);

    // init sets refcount to 1.
    try std.testing.expectEqual(@as(u32, 2), DropTarget.AddRef(&dt.obj));
    try std.testing.expectEqual(@as(u32, 3), DropTarget.AddRef(&dt.obj));
    try std.testing.expectEqual(@as(u32, 2), DropTarget.Release(&dt.obj));
    try std.testing.expectEqual(@as(u32, 1), DropTarget.Release(&dt.obj));
    try std.testing.expectEqual(@as(u32, 0), DropTarget.Release(&dt.obj));

    // Caller-owned: no auto-free on 0. Refcount is now 0.
    try std.testing.expectEqual(@as(u32, 0), dt.refcount.load(.acquire));
}

test "Modifier extraction from key_state maps shift/ctrl/alt correctly" {
    // No modifiers.
    const m0 = modifiersFromKeyState(0);
    try std.testing.expect(!m0.shift);
    try std.testing.expect(!m0.ctrl);
    try std.testing.expect(!m0.alt);

    // Shift only.
    const m1 = modifiersFromKeyState(MK_SHIFT);
    try std.testing.expect(m1.shift);
    try std.testing.expect(!m1.ctrl);
    try std.testing.expect(!m1.alt);

    // Ctrl only.
    const m2 = modifiersFromKeyState(MK_CONTROL);
    try std.testing.expect(!m2.shift);
    try std.testing.expect(m2.ctrl);
    try std.testing.expect(!m2.alt);

    // Alt only.
    const m3 = modifiersFromKeyState(MK_ALT);
    try std.testing.expect(!m3.shift);
    try std.testing.expect(!m3.ctrl);
    try std.testing.expect(m3.alt);

    // All three.
    const m4 = modifiersFromKeyState(MK_SHIFT | MK_CONTROL | MK_ALT);
    try std.testing.expect(m4.shift);
    try std.testing.expect(m4.ctrl);
    try std.testing.expect(m4.alt);
}

test "DragLeave resets has_accepted_format" {
    const noop = struct {
        fn cb(_: *anyopaque, _: []const u8) void {}
    }.cb;
    var dt = DropTarget.init(std.testing.allocator, @ptrFromInt(0x1), noop);
    dt.has_accepted_format = true;

    _ = DropTarget.DragLeave(&dt.obj);
    try std.testing.expect(!dt.has_accepted_format);
}
