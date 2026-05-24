//! OLE drag-source adapter for cross-window tab drag.
//!
//! Implements `IDataObject`, `IDropSource`, and `IEnumFORMATETC` as minimal
//! COM objects that ferry a `CF_WINGHOSTTY_TAB` payload through the system
//! `DoDragDrop` loop. The payload is intentionally process-local metadata
//! (PID + opaque pointer), not a serialised terminal/session image; drop
//! targets must reject it when the PID differs. Each struct is one-shot:
//! allocate, call `doDragDrop`, release.
//!
//! Thread safety: `doDragDrop` and all COM callbacks run on the STA-
//! initialised UI thread. The apprt arranges `CoInitializeEx(STA)` in
//! `App.init`; callers must not invoke from a background thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const ole_types = @import("win32_ole.zig");
const tab_drag = @import("win32_tab_drag.zig");
const win32_types = @import("win32_types.zig");

const log = std.log.scoped(.win32_tab_drag_ole);

// ── Win32 type aliases ─────────────────────────────────────────────────

const HRESULT = ole_types.HRESULT;
const GUID = ole_types.GUID;
const BOOL = win32_types.BOOL;
const DWORD = ole_types.DWORD;
const ULONG = ole_types.ULONG;
const WORD = ole_types.WORD;
const UINT = win32_types.UINT;

const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));

const DV_E_FORMATETC: HRESULT = @bitCast(@as(u32, 0x80040064));
const DATA_S_SAMEFORMATETC: HRESULT = @bitCast(@as(u32, 0x00040130));
const OLE_E_ADVISENOTSUPPORTED: HRESULT = @bitCast(@as(u32, 0x80040003));

const DRAGDROP_S_DROP: HRESULT = @bitCast(@as(u32, 0x00040100));
const DRAGDROP_S_CANCEL: HRESULT = @bitCast(@as(u32, 0x00040101));
const DRAGDROP_S_USEDEFAULTCURSORS: HRESULT = @bitCast(@as(u32, 0x00040102));

// Drop effects.
const DROPEFFECT_NONE: DWORD = 0;
const DROPEFFECT_COPY: DWORD = 1;
const DROPEFFECT_MOVE: DWORD = 2;

// TYMED flags.
const TYMED_HGLOBAL: DWORD = 1;

// DVASPECT.
const DVASPECT_CONTENT: DWORD = 1;
const DVASPECT_THUMBNAIL: DWORD = 2;

// DATADIR.
const DATADIR_GET: DWORD = 1;

// MK_ key-state flags.
const MK_LBUTTON: DWORD = 0x0001;

// GMEM flags.
const GMEM_MOVEABLE: UINT = 0x0002;

// ── IIDs ───────────────────────────────────────────────────────────────

const IID_IUnknown = ole_types.IID_IUnknown;
const IID_IDropSource = ole_types.IID_IDropSource;
const IID_IDataObject = ole_types.IID_IDataObject;
const IID_IEnumFORMATETC = ole_types.IID_IEnumFORMATETC;

// ── FORMATETC / STGMEDIUM ──────────────────────────────────────────────

const FORMATETC = ole_types.FORMATETC;
const STGMEDIUM = ole_types.STGMEDIUM;

// ── Payload type alias ─────────────────────────────────────────────────

const Payload = tab_drag.Payload;

// ── CF_WINGHOSTTY_TAB registration ─────────────────────────────────────

var cf_winghostty_tab_id: UINT = 0;

fn ensureClipboardFormat() UINT {
    if (cf_winghostty_tab_id != 0) return cf_winghostty_tab_id;
    const u32fns = loadUser32() orelse return 0;
    cf_winghostty_tab_id = u32fns.RegisterClipboardFormatW(
        std.unicode.utf8ToUtf16LeStringLiteral(tab_drag.clipboard_format_name),
    );
    return cf_winghostty_tab_id;
}

/// Public accessor so tests and callers can get the registered format ID.
pub fn clipboardFormatId() UINT {
    return ensureClipboardFormat();
}

// ── COM object shapes (bare vtbl pointers) ─────────────────────────────

const IDropSourceObj = extern struct {
    vtbl: *const IDropSourceVtbl,
};

const IDataObjectObj = ole_types.IDataObject;
const IEnumFORMATETCObj = ole_types.IEnumFORMATETC;

// ── V-table layouts ────────────────────────────────────────────────────

const IDropSourceVtbl = extern struct {
    // IUnknown (3)
    QueryInterface: *const fn (*IDropSourceObj, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDropSourceObj) callconv(.winapi) ULONG,
    Release: *const fn (*IDropSourceObj) callconv(.winapi) ULONG,
    // IDropSource (2)
    QueryContinueDrag: *const fn (*IDropSourceObj, BOOL, DWORD) callconv(.winapi) HRESULT,
    GiveFeedback: *const fn (*IDropSourceObj, DWORD) callconv(.winapi) HRESULT,
};

const IDataObjectVtbl = ole_types.IDataObjectVtbl;
const IEnumFORMATETCVtbl = ole_types.IEnumFORMATETCVtbl;

// ── Comptime v-table layout assertions ─────────────────────────────────

comptime {
    // IDropSource: 3 IUnknown + 2 methods = 5 slots.
    const ds_expected = 5 * @sizeOf(*anyopaque);
    if (@sizeOf(IDropSourceVtbl) != ds_expected) {
        @compileError(std.fmt.comptimePrint(
            "IDropSourceVtbl size mismatch: got {d}, expected {d}",
            .{ @sizeOf(IDropSourceVtbl), ds_expected },
        ));
    }
}

// ── Runtime-loaded functions ───────────────────────────────────────────

const Ole32Fns = struct {
    DoDragDrop: *const fn (*IDataObjectObj, *IDropSourceObj, DWORD, *DWORD) callconv(.winapi) HRESULT = undefined,
    ReleaseStgMedium: *const fn (*STGMEDIUM) callconv(.winapi) void = undefined,
    CoTaskMemFree: *const fn (?*anyopaque) callconv(.winapi) void = undefined,
};

const Kernel32Fns = struct {
    GlobalAlloc: *const fn (UINT, usize) callconv(.winapi) ?*anyopaque = undefined,
    GlobalFree: *const fn (?*anyopaque) callconv(.winapi) ?*anyopaque = undefined,
    GlobalLock: *const fn (?*anyopaque) callconv(.winapi) ?[*]u8 = undefined,
    GlobalUnlock: *const fn (?*anyopaque) callconv(.winapi) BOOL = undefined,
    GlobalSize: *const fn (?*anyopaque) callconv(.winapi) usize = undefined,
};

const User32Fns = struct {
    RegisterClipboardFormatW: *const fn ([*:0]const u16) callconv(.winapi) UINT = undefined,
};

var ole32_fns: ?Ole32Fns = null;
var kernel32_fns: ?Kernel32Fns = null;
var user32_fns: ?User32Fns = null;

fn loadOle32() ?Ole32Fns {
    if (ole32_fns) |fns| return fns;
    const dll = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("ole32.dll")) orelse return null;
    var fns: Ole32Fns = .{};
    fns.DoDragDrop = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "DoDragDrop") orelse return null));
    fns.ReleaseStgMedium = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "ReleaseStgMedium") orelse return null));
    fns.CoTaskMemFree = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "CoTaskMemFree") orelse return null));
    ole32_fns = fns;
    return fns;
}

fn loadKernel32() ?Kernel32Fns {
    if (kernel32_fns) |fns| return fns;
    const dll = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse return null;
    var fns: Kernel32Fns = .{};
    fns.GlobalAlloc = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "GlobalAlloc") orelse return null));
    fns.GlobalFree = @ptrCast(@alignCast(windows.kernel32.GetProcAddress(dll, "GlobalFree") orelse return null));
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

// ── Helpers ────────────────────────────────────────────────────────────

fn iidEqual(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn formatEtcMatches(fmt: *const FORMATETC, cf_id: WORD) bool {
    return fmt.cfFormat == cf_id and
        fmt.ptd == null and
        fmt.dwAspect == DVASPECT_CONTENT and
        fmt.lindex == -1 and
        fmt.tymed & TYMED_HGLOBAL != 0;
}

// ═══════════════════════════════════════════════════════════════════════
// DragSource (IDropSource)
// ═══════════════════════════════════════════════════════════════════════

pub const DragSource = struct {
    obj: IDropSourceObj,
    refcount: std.atomic.Value(u32),
    alloc: Allocator,

    const vtbl_impl: IDropSourceVtbl = .{
        .QueryInterface = DragSource.QueryInterface,
        .AddRef = DragSource.AddRef,
        .Release = DragSource.Release,
        .QueryContinueDrag = DragSource.QueryContinueDrag,
        .GiveFeedback = DragSource.GiveFeedback,
    };

    pub fn init(alloc: Allocator) DragSource {
        return .{
            .obj = .{ .vtbl = &vtbl_impl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *DragSource) void {
        if (std.debug.runtime_safety) {
            const rc = self.refcount.load(.acquire);
            std.debug.assert(rc == 0 or rc == 1);
        }
    }

    fn fromObj(p: *IDropSourceObj) *DragSource {
        return @fieldParentPtr("obj", p);
    }

    // ── IUnknown ────────────────────────────────────────────────────────

    fn QueryInterface(
        self_obj: *IDropSourceObj,
        iid: *const GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        out.* = null;
        if (iidEqual(iid, &IID_IUnknown) or iidEqual(iid, &IID_IDropSource)) {
            out.* = @ptrCast(&self.obj);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    fn AddRef(self_obj: *IDropSourceObj) callconv(.winapi) ULONG {
        const self = fromObj(self_obj);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Release(self_obj: *IDropSourceObj) callconv(.winapi) ULONG {
        const self = fromObj(self_obj);
        const prev = self.refcount.fetchSub(1, .acq_rel);
        return prev - 1;
    }

    // ── IDropSource ─────────────────────────────────────────────────────

    fn QueryContinueDrag(
        _: *IDropSourceObj,
        fEscapePressed: BOOL,
        grfKeyState: DWORD,
    ) callconv(.winapi) HRESULT {
        if (fEscapePressed != 0) return DRAGDROP_S_CANCEL;
        if (grfKeyState & MK_LBUTTON == 0) return DRAGDROP_S_DROP;
        return S_OK;
    }

    fn GiveFeedback(
        _: *IDropSourceObj,
        _: DWORD,
    ) callconv(.winapi) HRESULT {
        return DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// FormatEnumerator (IEnumFORMATETC)
// ═══════════════════════════════════════════════════════════════════════

pub const FormatEnumerator = struct {
    obj: IEnumFORMATETCObj,
    refcount: std.atomic.Value(u32),
    alloc: Allocator,
    fmt: FORMATETC,
    cursor: u32,

    const vtbl_impl: IEnumFORMATETCVtbl = .{
        .QueryInterface = FormatEnumerator.QueryInterface,
        .AddRef = FormatEnumerator.AddRef,
        .Release = FormatEnumerator.Release,
        .Next = FormatEnumerator.Next,
        .Skip = FormatEnumerator.Skip,
        .Reset = FormatEnumerator.Reset,
        .Clone = FormatEnumerator.CloneFn,
    };

    pub fn create(alloc: Allocator, cf_id: WORD, cursor: u32) ?*FormatEnumerator {
        const self = alloc.create(FormatEnumerator) catch return null;
        self.* = .{
            .obj = .{ .vtbl = &vtbl_impl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .fmt = .{
                .cfFormat = cf_id,
                .ptd = null,
                .dwAspect = DVASPECT_CONTENT,
                .lindex = -1,
                .tymed = TYMED_HGLOBAL,
            },
            .cursor = cursor,
        };
        return self;
    }

    fn fromObj(p: *IEnumFORMATETCObj) *FormatEnumerator {
        return @fieldParentPtr("obj", p);
    }

    // ── IUnknown ────────────────────────────────────────────────────────

    fn QueryInterface(
        self_obj: *IEnumFORMATETCObj,
        iid: *const GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        out.* = null;
        if (iidEqual(iid, &IID_IUnknown) or iidEqual(iid, &IID_IEnumFORMATETC)) {
            out.* = @ptrCast(&self.obj);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    fn AddRef(self_obj: *IEnumFORMATETCObj) callconv(.winapi) ULONG {
        const self = fromObj(self_obj);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Release(self_obj: *IEnumFORMATETCObj) callconv(.winapi) ULONG {
        const self = fromObj(self_obj);
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            const a = self.alloc;
            a.destroy(self);
        }
        return prev - 1;
    }

    // ── IEnumFORMATETC ──────────────────────────────────────────────────

    fn Next(
        self_obj: *IEnumFORMATETCObj,
        celt: ULONG,
        rgelt: [*]FORMATETC,
        pceltFetched: ?*ULONG,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        var fetched: ULONG = 0;

        if (self.cursor == 0 and celt >= 1) {
            rgelt[0] = self.fmt;
            self.cursor = 1;
            fetched = 1;
        }

        if (pceltFetched) |pf| pf.* = fetched;
        return if (fetched == celt) S_OK else S_FALSE;
    }

    fn Skip(
        self_obj: *IEnumFORMATETCObj,
        celt: ULONG,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        if (self.cursor == 0 and celt >= 1) {
            self.cursor = 1;
            return if (celt == 1) S_OK else S_FALSE;
        }
        return S_FALSE;
    }

    fn Reset(self_obj: *IEnumFORMATETCObj) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        self.cursor = 0;
        return S_OK;
    }

    fn CloneFn(
        self_obj: *IEnumFORMATETCObj,
        ppenum: *?*IEnumFORMATETCObj,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        const cloned = FormatEnumerator.create(self.alloc, self.fmt.cfFormat, self.cursor) orelse {
            ppenum.* = null;
            return E_OUTOFMEMORY;
        };
        ppenum.* = &cloned.obj;
        return S_OK;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// DataObject (IDataObject)
// ═══════════════════════════════════════════════════════════════════════

pub const DataObject = struct {
    obj: IDataObjectObj,
    refcount: std.atomic.Value(u32),
    alloc: Allocator,
    payload: Payload,
    cf_id: WORD,

    const vtbl_impl: IDataObjectVtbl = .{
        .QueryInterface = DataObject.QueryInterface,
        .AddRef = DataObject.AddRef,
        .Release = DataObject.Release,
        .GetData = DataObject.GetData,
        .GetDataHere = DataObject.GetDataHere,
        .QueryGetData = DataObject.QueryGetData,
        .GetCanonicalFormatEtc = DataObject.GetCanonicalFormatEtc,
        .SetData = DataObject.SetData,
        .EnumFormatEtc = DataObject.EnumFormatEtc,
        .DAdvise = DataObject.DAdvise,
        .DUnadvise = DataObject.DUnadvise,
        .EnumDAdvise = DataObject.EnumDAdvise,
    };

    pub fn init(alloc: Allocator, payload: Payload) ?DataObject {
        const cf_id = ensureClipboardFormat();
        if (cf_id == 0) return null;
        return .{
            .obj = .{ .vtbl = &vtbl_impl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .payload = payload,
            .cf_id = @intCast(cf_id),
        };
    }

    /// Construct for tests where `RegisterClipboardFormatW` may not be
    /// available. The caller supplies the format ID directly.
    fn initWithFormat(alloc: Allocator, payload: Payload, cf_id: WORD) DataObject {
        return .{
            .obj = .{ .vtbl = &vtbl_impl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .payload = payload,
            .cf_id = cf_id,
        };
    }

    pub fn deinit(self: *DataObject) void {
        if (std.debug.runtime_safety) {
            const rc = self.refcount.load(.acquire);
            std.debug.assert(rc == 0 or rc == 1);
        }
    }

    fn fromObj(p: *IDataObjectObj) *DataObject {
        return @fieldParentPtr("obj", p);
    }

    // ── IUnknown ────────────────────────────────────────────────────────

    fn QueryInterface(
        self_obj: *IDataObjectObj,
        iid: *const GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        out.* = null;
        if (iidEqual(iid, &IID_IUnknown) or iidEqual(iid, &IID_IDataObject)) {
            out.* = @ptrCast(&self.obj);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    fn AddRef(self_obj: *IDataObjectObj) callconv(.winapi) ULONG {
        const self = fromObj(self_obj);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Release(self_obj: *IDataObjectObj) callconv(.winapi) ULONG {
        const self = fromObj(self_obj);
        const prev = self.refcount.fetchSub(1, .acq_rel);
        return prev - 1;
    }

    // ── IDataObject ─────────────────────────────────────────────────────

    fn GetData(
        self_obj: *IDataObjectObj,
        pformatetc: *const FORMATETC,
        pmedium: *STGMEDIUM,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        pmedium.* = std.mem.zeroes(STGMEDIUM);

        if (!formatEtcMatches(pformatetc, self.cf_id)) return DV_E_FORMATETC;

        const k32 = loadKernel32() orelse return E_OUTOFMEMORY;
        const size = @sizeOf(Payload);
        const hGlobal = k32.GlobalAlloc(GMEM_MOVEABLE, size) orelse return E_OUTOFMEMORY;

        const locked = k32.GlobalLock(hGlobal) orelse {
            _ = k32.GlobalFree(hGlobal);
            return E_OUTOFMEMORY;
        };
        const src_bytes = std.mem.asBytes(&self.payload);
        @memcpy(locked[0..size], src_bytes);
        _ = k32.GlobalUnlock(hGlobal);

        pmedium.tymed = TYMED_HGLOBAL;
        pmedium.u = .{ .hGlobal = hGlobal };
        pmedium.pUnkForRelease = null;
        return S_OK;
    }

    fn GetDataHere(
        _: *IDataObjectObj,
        _: *const FORMATETC,
        _: *STGMEDIUM,
    ) callconv(.winapi) HRESULT {
        return E_NOTIMPL;
    }

    fn QueryGetData(
        self_obj: *IDataObjectObj,
        pformatetc: *const FORMATETC,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        if (formatEtcMatches(pformatetc, self.cf_id)) {
            return S_OK;
        }
        return DV_E_FORMATETC;
    }

    fn GetCanonicalFormatEtc(
        _: *IDataObjectObj,
        _: *const FORMATETC,
        _: *FORMATETC,
    ) callconv(.winapi) HRESULT {
        return DATA_S_SAMEFORMATETC;
    }

    fn SetData(
        _: *IDataObjectObj,
        _: *const FORMATETC,
        _: *STGMEDIUM,
        _: BOOL,
    ) callconv(.winapi) HRESULT {
        return E_NOTIMPL;
    }

    fn EnumFormatEtc(
        self_obj: *IDataObjectObj,
        dwDirection: DWORD,
        out_enum: *?*IEnumFORMATETCObj,
    ) callconv(.winapi) HRESULT {
        const self = fromObj(self_obj);
        out_enum.* = null;
        if (dwDirection != DATADIR_GET) return E_NOTIMPL;
        const enumerator = FormatEnumerator.create(self.alloc, self.cf_id, 0) orelse {
            return E_OUTOFMEMORY;
        };
        out_enum.* = &enumerator.obj;
        return S_OK;
    }

    fn DAdvise(
        _: *IDataObjectObj,
        _: *const FORMATETC,
        _: DWORD,
        _: ?*anyopaque,
        _: *DWORD,
    ) callconv(.winapi) HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }

    fn DUnadvise(
        _: *IDataObjectObj,
        _: DWORD,
    ) callconv(.winapi) HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }

    fn EnumDAdvise(
        _: *IDataObjectObj,
        _: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Public entry point
// ═══════════════════════════════════════════════════════════════════════

pub const DoDragError = error{
    DataObjectInitFailed,
    DoDragDropFailed,
    RuntimeMissing,
};

pub const DragResult = enum {
    dropped,
    cancelled,
    failed,
};

/// Initiate an OLE drag-drop loop carrying `payload` as `CF_WINGHOSTTY_TAB`.
///
/// Blocks until the user drops or cancels. Returns the drag outcome;
/// `drop_effect` receives the negotiated `DROPEFFECT` on success.
///
/// Requires the calling thread to have `CoInitializeEx(STA)`, which the
/// apprt arranges in `App.init`.
pub fn doDragDrop(alloc: Allocator, payload: Payload, drop_effect: *DWORD) DoDragError!DragResult {
    const ole = loadOle32() orelse return error.RuntimeMissing;

    var dataobj = DataObject.init(alloc, payload) orelse return error.DataObjectInitFailed;
    defer dataobj.deinit();

    var source = DragSource.init(alloc);
    defer source.deinit();

    const hr = ole.DoDragDrop(
        &dataobj.obj,
        &source.obj,
        DROPEFFECT_MOVE | DROPEFFECT_COPY,
        drop_effect,
    );

    // Release both COM objects (symmetry with the init refcount of 1).
    _ = DragSource.Release(&source.obj);
    _ = DataObject.Release(&dataobj.obj);

    if (hr == DRAGDROP_S_DROP) return .dropped;
    if (hr == DRAGDROP_S_CANCEL) return .cancelled;
    // Any negative HRESULT is a failure.
    if (hr < 0) {
        log.warn("DoDragDrop failed: 0x{x}", .{@as(u32, @bitCast(hr))});
        return .failed;
    }
    // Unexpected success code — treat as dropped.
    return .dropped;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// Synthetic format ID used in tests (avoids needing RegisterClipboardFormatW).
const TEST_CF: WORD = 0xC100;

fn makeTestPayload() Payload {
    return .{
        .magic = Payload.magic_value,
        .version = 1,
        .pid = 42,
        .state_ptr = 0xDEAD_BEEF,
    };
}

test "QueryGetData returns S_OK for matching format, DV_E_FORMATETC otherwise" {
    var dobj = DataObject.initWithFormat(testing.allocator, makeTestPayload(), TEST_CF);

    // Matching format + TYMED_HGLOBAL → S_OK.
    var fmt_good = FORMATETC{
        .cfFormat = TEST_CF,
        .ptd = null,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
    try testing.expectEqual(S_OK, DataObject.QueryGetData(&dobj.obj, &fmt_good));

    // Wrong format → DV_E_FORMATETC.
    var fmt_bad_cf = FORMATETC{
        .cfFormat = 0x0001,
        .ptd = null,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
    try testing.expectEqual(DV_E_FORMATETC, DataObject.QueryGetData(&dobj.obj, &fmt_bad_cf));

    // Wrong tymed → DV_E_FORMATETC.
    var fmt_bad_tymed = FORMATETC{
        .cfFormat = TEST_CF,
        .ptd = null,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = 0, // not TYMED_HGLOBAL
    };
    try testing.expectEqual(DV_E_FORMATETC, DataObject.QueryGetData(&dobj.obj, &fmt_bad_tymed));

    // Wrong aspect -> DV_E_FORMATETC. The tab payload is only meaningful
    // as ordinary content, not thumbnail/icon/alternate render data.
    var fmt_bad_aspect = FORMATETC{
        .cfFormat = TEST_CF,
        .ptd = null,
        .dwAspect = DVASPECT_THUMBNAIL,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
    try testing.expectEqual(DV_E_FORMATETC, DataObject.QueryGetData(&dobj.obj, &fmt_bad_aspect));

    var target_device: u8 = 0;
    var fmt_bad_target_device = FORMATETC{
        .cfFormat = TEST_CF,
        .ptd = &target_device,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
    try testing.expectEqual(DV_E_FORMATETC, DataObject.QueryGetData(&dobj.obj, &fmt_bad_target_device));

    // Indexed requests are unsupported; this object offers exactly one
    // process-local tab metadata blob.
    var fmt_bad_lindex = FORMATETC{
        .cfFormat = TEST_CF,
        .ptd = null,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = 0,
        .tymed = TYMED_HGLOBAL,
    };
    try testing.expectEqual(DV_E_FORMATETC, DataObject.QueryGetData(&dobj.obj, &fmt_bad_lindex));
}

test "GetData allocates HGLOBAL with correct payload bytes" {
    const k32 = loadKernel32() orelse return error.SkipZigTest;

    const payload = makeTestPayload();
    var dobj = DataObject.initWithFormat(testing.allocator, payload, TEST_CF);

    var fmt = FORMATETC{
        .cfFormat = TEST_CF,
        .ptd = null,
        .dwAspect = DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
    var stg: STGMEDIUM = std.mem.zeroes(STGMEDIUM);

    const hr = DataObject.GetData(&dobj.obj, &fmt, &stg);
    try testing.expectEqual(S_OK, hr);
    try testing.expectEqual(TYMED_HGLOBAL, stg.tymed);
    try testing.expect(stg.u.hGlobal != null);

    // Verify contents.
    const locked = k32.GlobalLock(stg.u.hGlobal) orelse return error.SkipZigTest;
    defer _ = k32.GlobalUnlock(stg.u.hGlobal);

    const expected = std.mem.asBytes(&payload);
    const actual = locked[0..@sizeOf(Payload)];
    try testing.expectEqualSlices(u8, expected, actual);

    // Clean up.
    _ = k32.GlobalFree(stg.u.hGlobal);
}

test "GetData rejects unsupported FORMATETC variants before allocating" {
    const payload = makeTestPayload();
    var dobj = DataObject.initWithFormat(testing.allocator, payload, TEST_CF);

    var fmt_bad_aspect = FORMATETC{
        .cfFormat = TEST_CF,
        .ptd = null,
        .dwAspect = DVASPECT_THUMBNAIL,
        .lindex = -1,
        .tymed = TYMED_HGLOBAL,
    };
    var stg: STGMEDIUM = undefined;

    const hr = DataObject.GetData(&dobj.obj, &fmt_bad_aspect, &stg);
    try testing.expectEqual(DV_E_FORMATETC, hr);
    try testing.expectEqual(@as(DWORD, 0), stg.tymed);
    try testing.expect(stg.u.raw == null);
    try testing.expect(stg.pUnkForRelease == null);

    var fmt_bad_lindex = fmt_bad_aspect;
    fmt_bad_lindex.dwAspect = DVASPECT_CONTENT;
    fmt_bad_lindex.lindex = 0;
    stg = undefined;

    const lindex_hr = DataObject.GetData(&dobj.obj, &fmt_bad_lindex, &stg);
    try testing.expectEqual(DV_E_FORMATETC, lindex_hr);
    try testing.expectEqual(@as(DWORD, 0), stg.tymed);
    try testing.expect(stg.u.raw == null);
    try testing.expect(stg.pUnkForRelease == null);
}

test "FormatEnumerator.Next returns one format then S_FALSE" {
    const enumerator = FormatEnumerator.create(testing.allocator, TEST_CF, 0) orelse
        return error.SkipZigTest;
    defer _ = FormatEnumerator.Release(&enumerator.obj);

    var fmt: FORMATETC = undefined;
    var fetched: ULONG = 0;

    // First call: should return 1 format.
    const hr1 = FormatEnumerator.Next(&enumerator.obj, 1, @ptrCast(&fmt), &fetched);
    try testing.expectEqual(S_OK, hr1);
    try testing.expectEqual(@as(ULONG, 1), fetched);
    try testing.expectEqual(TEST_CF, fmt.cfFormat);
    try testing.expectEqual(TYMED_HGLOBAL, fmt.tymed);
    try testing.expectEqual(DVASPECT_CONTENT, fmt.dwAspect);

    // Second call: exhausted → S_FALSE.
    fetched = 99;
    const hr2 = FormatEnumerator.Next(&enumerator.obj, 1, @ptrCast(&fmt), &fetched);
    try testing.expectEqual(S_FALSE, hr2);
    try testing.expectEqual(@as(ULONG, 0), fetched);
}

test "DragSource.QueryContinueDrag maps Esc/button/steady correctly" {
    var source = DragSource.init(testing.allocator);

    // Escape pressed → CANCEL.
    try testing.expectEqual(
        DRAGDROP_S_CANCEL,
        DragSource.QueryContinueDrag(&source.obj, 1, MK_LBUTTON),
    );

    // Left button released (no Esc) → DROP.
    try testing.expectEqual(
        DRAGDROP_S_DROP,
        DragSource.QueryContinueDrag(&source.obj, 0, 0),
    );

    // Left button held, no Esc → S_OK (continue).
    try testing.expectEqual(
        S_OK,
        DragSource.QueryContinueDrag(&source.obj, 0, MK_LBUTTON),
    );
}

test "FormatEnumerator.Reset re-enables iteration" {
    const enumerator = FormatEnumerator.create(testing.allocator, TEST_CF, 0) orelse
        return error.SkipZigTest;
    defer _ = FormatEnumerator.Release(&enumerator.obj);

    var fmt: FORMATETC = undefined;
    var fetched: ULONG = 0;

    // Consume the one entry.
    _ = FormatEnumerator.Next(&enumerator.obj, 1, @ptrCast(&fmt), &fetched);
    try testing.expectEqual(@as(ULONG, 1), fetched);

    // Exhausted.
    fetched = 0;
    const hr_empty = FormatEnumerator.Next(&enumerator.obj, 1, @ptrCast(&fmt), &fetched);
    try testing.expectEqual(S_FALSE, hr_empty);

    // Reset.
    try testing.expectEqual(S_OK, FormatEnumerator.Reset(&enumerator.obj));

    // Should yield the entry again.
    fetched = 0;
    const hr_again = FormatEnumerator.Next(&enumerator.obj, 1, @ptrCast(&fmt), &fetched);
    try testing.expectEqual(S_OK, hr_again);
    try testing.expectEqual(@as(ULONG, 1), fetched);
}

test "FormatEnumerator.Clone preserves cursor position" {
    const enumerator = FormatEnumerator.create(testing.allocator, TEST_CF, 0) orelse
        return error.SkipZigTest;
    defer _ = FormatEnumerator.Release(&enumerator.obj);

    // Advance cursor to exhausted.
    var fmt: FORMATETC = undefined;
    _ = FormatEnumerator.Next(&enumerator.obj, 1, @ptrCast(&fmt), null);

    // Clone from exhausted state.
    var cloned_obj: ?*IEnumFORMATETCObj = null;
    const hr = FormatEnumerator.CloneFn(&enumerator.obj, &cloned_obj);
    try testing.expectEqual(S_OK, hr);
    try testing.expect(cloned_obj != null);

    const cloned = cloned_obj.?;
    defer _ = cloned.vtbl.Release(cloned);

    // Cloned should also be exhausted.
    var fetched: ULONG = 0;
    const hr2 = cloned.vtbl.Next(cloned, 1, @ptrCast(&fmt), &fetched);
    try testing.expectEqual(S_FALSE, hr2);
    try testing.expectEqual(@as(ULONG, 0), fetched);
}

test "DataObject.EnumFormatEtc returns enumerator for DATADIR_GET" {
    var dobj = DataObject.initWithFormat(testing.allocator, makeTestPayload(), TEST_CF);

    var out_enum: ?*IEnumFORMATETCObj = null;
    const hr = DataObject.EnumFormatEtc(&dobj.obj, DATADIR_GET, &out_enum);
    try testing.expectEqual(S_OK, hr);
    try testing.expect(out_enum != null);

    const e = out_enum.?;
    defer _ = e.vtbl.Release(e);

    // Should list exactly one format.
    var fmt: FORMATETC = undefined;
    var fetched: ULONG = 0;
    try testing.expectEqual(S_OK, e.vtbl.Next(e, 1, @ptrCast(&fmt), &fetched));
    try testing.expectEqual(@as(ULONG, 1), fetched);
    try testing.expectEqual(TEST_CF, fmt.cfFormat);

    // Non-GET direction → E_NOTIMPL.
    var out2: ?*IEnumFORMATETCObj = null;
    try testing.expectEqual(E_NOTIMPL, DataObject.EnumFormatEtc(&dobj.obj, 2, &out2));
}

test "DragSource AddRef/Release refcount" {
    var source = DragSource.init(testing.allocator);
    try testing.expectEqual(@as(u32, 2), DragSource.AddRef(&source.obj));
    try testing.expectEqual(@as(u32, 1), DragSource.Release(&source.obj));
    try testing.expectEqual(@as(u32, 0), DragSource.Release(&source.obj));
}

test "DataObject QueryInterface" {
    var dobj = DataObject.initWithFormat(testing.allocator, makeTestPayload(), TEST_CF);

    var out: ?*anyopaque = null;
    try testing.expectEqual(S_OK, DataObject.QueryInterface(&dobj.obj, &IID_IDataObject, &out));
    try testing.expect(out != null);
    _ = DataObject.Release(&dobj.obj);

    var out2: ?*anyopaque = null;
    try testing.expectEqual(S_OK, DataObject.QueryInterface(&dobj.obj, &IID_IUnknown, &out2));
    try testing.expect(out2 != null);
    _ = DataObject.Release(&dobj.obj);

    var out3: ?*anyopaque = null;
    const bogus = GUID.parse("{DEADBEEF-0000-0000-0000-000000000000}");
    try testing.expectEqual(E_NOINTERFACE, DataObject.QueryInterface(&dobj.obj, &bogus, &out3));
    try testing.expect(out3 == null);
}

test "GiveFeedback returns DRAGDROP_S_USEDEFAULTCURSORS" {
    var source = DragSource.init(testing.allocator);
    try testing.expectEqual(DRAGDROP_S_USEDEFAULTCURSORS, DragSource.GiveFeedback(&source.obj, 0));
    try testing.expectEqual(DRAGDROP_S_USEDEFAULTCURSORS, DragSource.GiveFeedback(&source.obj, DROPEFFECT_MOVE));
}
