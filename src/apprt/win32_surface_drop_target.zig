//! COM `IDropTarget` implementation for noctty terminal surfaces.
//!
//! Wraps the payload-parsing logic in `win32_surface_drop.zig` behind the
//! standard OLE drag-drop COM interface so Explorer (and any other drag
//! source) can drop files, text, URLs, and HTML onto a terminal pane.
//!
//! Lifetime: heap-allocated and COM-refcounted. The surface owns one
//! reference, clears its context before revoke, then releases its reference.
//! Retained COM references keep detached targets alive until final Release.
//!
//! Thread safety: all COM callbacks arrive on the thread that called
//! `RegisterDragDrop`, which MUST be the STA-initialised UI thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("win32/sys.zig");
const consts = @import("win32/consts.zig");
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

const DRAGDROP_E_NOTREGISTERED: HRESULT = @bitCast(@as(u32, 0x80040100));
const CO_E_NOTINITIALIZED: HRESULT = @bitCast(@as(u32, 0x800401F0));

// Drop effects.
const DROPEFFECT_NONE: DWORD = 0;
const DROPEFFECT_COPY: DWORD = 1;

// Clipboard formats (well-known constants).
const CF_HDROP: WORD = consts.CF_HDROP;
const CF_UNICODETEXT: WORD = consts.CF_UNICODETEXT;

// MK_ key-state flags present in `grfKeyState`.
const MK_SHIFT: DWORD = consts.MK_SHIFT;
const MK_CONTROL: DWORD = consts.MK_CONTROL;
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

/// Registered URL format ID, used only on the STA UI thread.
var cf_shellurl_id: UINT = 0;

fn ensureCustomFormats() void {
    _ = ole_types.htmlFormat();
    if (cf_shellurl_id == 0) {
        cf_shellurl_id = sys.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("UniformResourceLocator"));
    }
}

// ── DropTarget (public API) ────────────────────────────────────────────

pub const PayloadFn = *const fn (surface_ctx: *anyopaque, payload: []const u8) void;

pub const RegError = error{ RegisterFailed, OleNotInitialized };

pub const DropTarget = struct {
    /// COM object header — MUST be first field so `&self == &self.obj`.
    obj: IDropTargetObj,
    refcount: std.atomic.Value(u32),
    alloc: Allocator,
    surface_ctx: ?*anyopaque,
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

    fn init(alloc: Allocator, surface_ctx: *anyopaque, on_payload: PayloadFn) DropTarget {
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

    pub fn create(alloc: Allocator, surface_ctx: *anyopaque, on_payload: PayloadFn) Allocator.Error!*DropTarget {
        const self = try alloc.create(DropTarget);
        self.* = init(alloc, surface_ctx, on_payload);
        return self;
    }

    pub fn register(self: *DropTarget, hwnd: HWND) RegError!void {
        const hr = sys.RegisterDragDrop(hwnd, @ptrCast(&self.obj));
        if (hr == S_OK) return;
        if (hr == CO_E_NOTINITIALIZED) return error.OleNotInitialized;
        // ALREADYREGISTERED belongs to the existing target, not this object.
        return error.RegisterFailed;
    }

    pub fn detach(self: *DropTarget) void {
        self.surface_ctx = null;
        self.has_accepted_format = false;
    }

    pub fn revoke(self: *DropTarget, hwnd: HWND) void {
        self.detach();
        const hr = sys.RevokeDragDrop(hwnd);
        if (hr != S_OK and hr != DRAGDROP_E_NOTREGISTERED) {
            log.warn("RevokeDragDrop failed: 0x{x}", .{@as(u32, @bitCast(hr))});
        }
    }

    /// Release the surface's reference; clients may still retain this target.
    pub fn deinit(self: *DropTarget) void {
        self.detach();
        _ = Release(&self.obj);
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
        std.debug.assert(prev > 0);
        if (prev == 1) self.alloc.destroy(self);
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
        _ = AddRef(self_obj);
        defer _ = Release(self_obj);
        if (self.surface_ctx == null) {
            pdwEffect.* = DROPEFFECT_NONE;
            return S_OK;
        }
        const accepted = probeFormats(data_object);
        // Probing calls into the data object, which can detach the target.
        self.has_accepted_format = self.surface_ctx != null and accepted;
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
        pdwEffect.* = if (self.surface_ctx != null and self.has_accepted_format) DROPEFFECT_COPY else DROPEFFECT_NONE;
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
        // GetData and the payload callback can reenter surface destruction.
        _ = AddRef(self_obj);
        defer _ = Release(self_obj);
        defer self.has_accepted_format = false;
        pdwEffect.* = DROPEFFECT_NONE;
        if (self.surface_ctx == null) return S_OK;

        const mods = modifiersFromKeyState(grfKeyState);

        // Try formats in priority order.
        const payload = self.tryExtractHdrop(data_object, mods) orelse
            self.tryExtractUnicodeText(data_object, mods) orelse
            self.tryExtractHtml(data_object, mods) orelse
            self.tryExtractShellUrl(data_object) orelse
            return S_OK;
        defer self.alloc.free(payload);
        const ctx = self.surface_ctx orelse return S_OK;
        self.on_payload(ctx, payload);
        pdwEffect.* = DROPEFFECT_COPY;
        return S_OK;
    }

    // ── Format extraction helpers ───────────────────────────────────────

    fn tryExtractHdrop(self: *DropTarget, data_object: *IDataObject, mods: drop.Modifiers) ?[]u8 {
        var fmt = FORMATETC{
            .cfFormat = CF_HDROP,
            .ptd = null,
            .dwAspect = DVASPECT_CONTENT,
            .lindex = -1,
            .tymed = TYMED_HGLOBAL,
        };
        var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

        if (data_object.vtbl.GetData(data_object, &fmt, &stg) != S_OK) return null;
        defer sys.ReleaseStgMedium(&stg);

        const hDrop = stg.u.hGlobal orelse return null;
        const payload = ole_types.extractHdrop(self.alloc, hDrop, mods) catch return null;
        if (payload.len == 0) {
            self.alloc.free(payload);
            return null;
        }
        return payload;
    }

    fn tryExtractUnicodeText(self: *DropTarget, data_object: *IDataObject, mods: drop.Modifiers) ?[]u8 {
        var fmt = FORMATETC{
            .cfFormat = CF_UNICODETEXT,
            .ptd = null,
            .dwAspect = DVASPECT_CONTENT,
            .lindex = -1,
            .tymed = TYMED_HGLOBAL,
        };
        var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

        if (data_object.vtbl.GetData(data_object, &fmt, &stg) != S_OK) return null;
        defer sys.ReleaseStgMedium(&stg);

        const hGlobal = stg.u.hGlobal orelse return null;
        const locked: [*]const u16 = @ptrCast(@alignCast(sys.GlobalLock(hGlobal) orelse return null));
        defer _ = sys.GlobalUnlock(hGlobal);

        // Find the null terminator or use GlobalSize.
        const byte_size = sys.GlobalSize(hGlobal);
        const max_u16 = byte_size / 2;
        var len: usize = 0;
        while (len < max_u16 and locked[len] != 0) : (len += 1) {}

        if (len == 0) return null;

        // A lone surrogate becomes U+FFFD rather than refusing the drop,
        // as on the clipboard paste path.
        const utf8 = std.unicode.wtf16LeToWtf8Alloc(self.alloc, locked[0..len]) catch return null;
        defer self.alloc.free(utf8);
        std.unicode.wtf8ToUtf8Lossy(utf8, utf8) catch unreachable; // WTF-16 always gives WTF-8

        return drop.formatTextPayload(self.alloc, utf8, mods) catch null;
    }

    fn tryExtractHtml(self: *DropTarget, data_object: *IDataObject, mods: drop.Modifiers) ?[]u8 {
        if (ole_types.htmlFormat() == 0) return null;

        var fmt = FORMATETC{
            .cfFormat = @intCast(ole_types.htmlFormat()),
            .ptd = null,
            .dwAspect = DVASPECT_CONTENT,
            .lindex = -1,
            .tymed = TYMED_HGLOBAL,
        };
        var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

        if (data_object.vtbl.GetData(data_object, &fmt, &stg) != S_OK) return null;
        defer sys.ReleaseStgMedium(&stg);

        const hGlobal = stg.u.hGlobal orelse return null;
        const locked: [*]const u8 = @ptrCast(sys.GlobalLock(hGlobal) orelse return null);
        defer _ = sys.GlobalUnlock(hGlobal);

        const byte_size = sys.GlobalSize(hGlobal);
        if (byte_size == 0) return null;

        // CF_HTML is UTF-8 encoded with a header. Extract the fragment.
        const fragment = drop.extractHtmlFragment(locked[0..byte_size]);
        if (fragment.len == 0) return null;

        return drop.formatTextPayload(self.alloc, fragment, mods) catch null;
    }

    fn tryExtractShellUrl(self: *DropTarget, data_object: *IDataObject) ?[]u8 {
        if (cf_shellurl_id == 0) return null;

        var fmt = FORMATETC{
            .cfFormat = @intCast(cf_shellurl_id),
            .ptd = null,
            .dwAspect = DVASPECT_CONTENT,
            .lindex = -1,
            .tymed = TYMED_HGLOBAL,
        };
        var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

        if (data_object.vtbl.GetData(data_object, &fmt, &stg) != S_OK) return null;
        defer sys.ReleaseStgMedium(&stg);

        const hGlobal = stg.u.hGlobal orelse return null;
        const locked: [*]const u8 = @ptrCast(sys.GlobalLock(hGlobal) orelse return null);
        defer _ = sys.GlobalUnlock(hGlobal);

        const byte_size = sys.GlobalSize(hGlobal);
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
                if (ole_types.htmlFormat() != 0 and fmt.cfFormat == @as(WORD, @intCast(ole_types.htmlFormat()))) return true;
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
        (ole_types.htmlFormat() != 0 and queryGetDataForFormat(data_object, @as(WORD, @intCast(ole_types.htmlFormat())))) or
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
    const dt = try DropTarget.create(std.testing.allocator, @ptrFromInt(0x1), noop);
    defer dt.deinit();

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
    const dt = try DropTarget.create(std.testing.allocator, @ptrFromInt(0x1), noop);
    defer dt.deinit();

    // init sets refcount to 1.
    try std.testing.expectEqual(@as(u32, 2), DropTarget.AddRef(&dt.obj));
    try std.testing.expectEqual(@as(u32, 3), DropTarget.AddRef(&dt.obj));
    try std.testing.expectEqual(@as(u32, 2), DropTarget.Release(&dt.obj));
    try std.testing.expectEqual(@as(u32, 1), DropTarget.Release(&dt.obj));
    // The deferred deinit releases the final owning reference.
}

test "retained DropTarget final Release frees its allocation" {
    const noop = struct {
        fn cb(_: *anyopaque, _: []const u8) void {}
    }.cb;
    const dt = try std.testing.allocator.create(DropTarget);
    dt.* = DropTarget.init(std.testing.allocator, @ptrFromInt(0x1), noop);
    try std.testing.expectEqual(@as(u32, 2), DropTarget.AddRef(&dt.obj));
    // The surface drops its reference while an OLE client still owns one.
    try std.testing.expectEqual(@as(u32, 1), DropTarget.Release(&dt.obj));
    _ = DropTarget.DragLeave(&dt.obj);
    try std.testing.expectEqual(@as(u32, 0), DropTarget.Release(&dt.obj));
    // testing.allocator verifies that the final COM Release freed storage.
}

test "retained detached DropTarget rejects every drag callback" {
    const noop = struct {
        fn cb(_: *anyopaque, _: []const u8) void {
            @panic("detached target delivered a payload");
        }
    }.cb;
    const dt = try DropTarget.create(std.testing.allocator, @ptrFromInt(1), noop);
    _ = DropTarget.AddRef(&dt.obj);
    dt.deinit(); // The surface is gone; the retained client is still alive.
    defer _ = DropTarget.Release(&dt.obj);
    var data: IDataObject = .{ .vtbl = undefined }; // Must never be called.
    var effect: DWORD = DROPEFFECT_COPY;
    try std.testing.expectEqual(S_OK, DropTarget.DragEnter(&dt.obj, &data, 0, .{ .x = 0, .y = 0 }, &effect));
    try std.testing.expectEqual(DROPEFFECT_NONE, effect);
    dt.has_accepted_format = true; // Guard context even with stale cached state.
    effect = DROPEFFECT_COPY;
    try std.testing.expectEqual(S_OK, DropTarget.DragOver(&dt.obj, 0, .{ .x = 0, .y = 0 }, &effect));
    try std.testing.expectEqual(DROPEFFECT_NONE, effect);
    effect = DROPEFFECT_COPY;
    try std.testing.expectEqual(S_OK, DropTarget.handleDrop(&dt.obj, &data, 0, .{ .x = 0, .y = 0 }, &effect));
    try std.testing.expectEqual(DROPEFFECT_NONE, effect);
    try std.testing.expectEqual(S_OK, DropTarget.DragLeave(&dt.obj));
}

test "DropTarget GetData reentry can destroy the surface before payload delivery" {
    const Source = struct {
        obj: IDataObject,
        target: *DropTarget,
        const source_vtbl: ole_types.IDataObjectVtbl = .{
            .QueryInterface = undefined,
            .AddRef = undefined,
            .Release = undefined,
            .GetData = getData,
            .GetDataHere = undefined,
            .QueryGetData = undefined,
            .GetCanonicalFormatEtc = undefined,
            .SetData = undefined,
            .EnumFormatEtc = undefined,
            .DAdvise = undefined,
            .DUnadvise = undefined,
            .EnumDAdvise = undefined,
        };
        fn getData(obj: *IDataObject, fmt: *const FORMATETC, medium: *STGMEDIUM) callconv(.winapi) HRESULT {
            if (fmt.cfFormat != CF_UNICODETEXT) return E_FAIL;
            const self: *@This() = @fieldParentPtr("obj", obj);
            const text = std.unicode.utf8ToUtf16LeStringLiteral("payload");
            const bytes = std.mem.sliceAsBytes(text[0 .. text.len + 1]);
            const handle = sys.GlobalAlloc(2, bytes.len) orelse return E_FAIL;
            const locked: [*]u8 = @ptrCast(sys.GlobalLock(handle) orelse {
                _ = sys.GlobalFree(handle);
                return E_FAIL;
            });
            @memcpy(locked[0..bytes.len], bytes);
            _ = sys.GlobalUnlock(handle);
            medium.* = .{ .tymed = TYMED_HGLOBAL, .u = .{ .hGlobal = handle }, .pUnkForRelease = null };
            self.target.deinit(); // Releases the only surface reference mid-call.
            return S_OK;
        }
        fn payload(_: *anyopaque, _: []const u8) void {
            @panic("GetData delivered to a destroyed surface");
        }
    };
    const dt = try DropTarget.create(std.testing.allocator, @ptrFromInt(1), Source.payload);
    var source: Source = .{ .obj = .{ .vtbl = &Source.source_vtbl }, .target = dt };
    var effect: DWORD = DROPEFFECT_COPY;
    try std.testing.expectEqual(S_OK, DropTarget.handleDrop(&dt.obj, &source.obj, 0, .{ .x = 0, .y = 0 }, &effect));
    try std.testing.expectEqual(DROPEFFECT_NONE, effect);
    // The callback's temporary ref kept it alive; its return freed the target.
}

test "OLE STA initialization allows DropTarget registration on an unshown window" {
    const Fixture = struct {
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.result = check();
        }
        fn payload(_: *anyopaque, _: []const u8) void {}
        fn check() !void {
            const hr = sys.OleInitialize(null);
            try std.testing.expect(hr == S_OK or hr == 1);
            defer sys.OleUninitialize();
            const hwnd = sys.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), 0, 0, 0, 1, 1, null, null, null, null) orelse return error.WindowCreationFailed;
            defer _ = sys.DestroyWindow(hwnd);
            const dt = try DropTarget.create(std.testing.allocator, @ptrFromInt(1), payload);
            defer dt.deinit();
            try dt.register(hwnd);
            defer dt.revoke(hwnd);
            // A failed second registration must not acquire ownership of the HWND.
            const other = try DropTarget.create(std.testing.allocator, @ptrFromInt(1), payload);
            defer other.deinit();
            try std.testing.expectError(error.RegisterFailed, other.register(hwnd));
        }
    };
    var fixture: Fixture = .{};
    const thread = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    thread.join();
    try fixture.result;
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
    const dt = try DropTarget.create(std.testing.allocator, @ptrFromInt(0x1), noop);
    defer dt.deinit();
    dt.has_accepted_format = true;

    _ = DropTarget.DragLeave(&dt.obj);
    try std.testing.expect(!dt.has_accepted_format);
}
