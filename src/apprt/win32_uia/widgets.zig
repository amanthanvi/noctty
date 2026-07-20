//! Per-widget UIA providers.
//!
//! One provider per widget, mirroring `RootProvider`'s refcounted
//! `IRawElementProviderSimple` shape. Per AGENTS.md:52, every widget
//! HWND must route `WM_GETOBJECT(UiaRootObjectId)` into a provider
//! here — retrofitting accessibility is where accessibility debt
//! lives.
//!
//! Current widgets:
//!   * `PaletteListProvider` — the command palette row list. Reports
//!     ControlType=List with a live name that names the currently
//!     selected match so Narrator announces it on arrow-key nav.
//!   * `TerminalProvider` — the terminal child HWND. Reports
//!     ControlType=Document and exposes terminal content through TextPattern.
//!
//! The owner-drawn palette list is a fragment root. Its rows are ephemeral
//! fragment/SelectionItem providers backed by live widget state; native HWND
//! controls continue to use the system provider.

const std = @import("std");
const com = @import("com.zig");
const constants = @import("constants.zig");
const terminal_text = @import("text.zig");

const POINT = extern struct {
    x: i32,
    y: i32,
};

const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

extern "user32" fn GetClientRect(hWnd: com.HWND, lpRect: *RECT) callconv(.winapi) com.BOOL;
extern "user32" fn ScreenToClient(hWnd: com.HWND, lpPoint: *POINT) callconv(.winapi) com.BOOL;
extern "user32" fn ClientToScreen(hWnd: com.HWND, lpPoint: *POINT) callconv(.winapi) com.BOOL;
extern "kernel32" fn CompareStringOrdinal(
    lpString1: [*]const u16,
    cchCount1: i32,
    lpString2: [*]const u16,
    cchCount2: i32,
    bIgnoreCase: com.BOOL,
) callconv(.winapi) i32;

/// Shape-of-life contract callers implement so the provider can ask
/// the owning widget for its current live text. Decouples the
/// provider from `Host` (which lives in `win32.zig` and would pull a
/// cycle into this module).
pub const PaletteListState = struct {
    ctx: *anyopaque,
    /// Fill `buf` with the provider's current Name string and return
    /// the slice actually written. A typical implementation writes
    /// something like "Command palette: 3 of 87 — New Tab".
    name: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
    row_count: ?*const fn (ctx: *anyopaque) usize = null,
    selected_index: ?*const fn (ctx: *anyopaque) ?usize = null,
    row_name: ?*const fn (ctx: *anyopaque, index: usize, buf: []u8) []const u8 = null,
    row_enabled: ?*const fn (ctx: *anyopaque, index: usize) bool = null,
    row_id: ?*const fn (ctx: *anyopaque, index: usize) u64 = null,
    select_row: ?*const fn (ctx: *anyopaque, index: usize) void = null,
    geometry: ?*const fn (ctx: *anyopaque) ?PaletteListGeometry = null,
};

pub const PaletteListGeometry = struct {
    bounds: com.UiaRect,
    first_visible: usize,
    visible_count: usize,
    row_height: f64,
};

pub const TerminalState = struct {
    ctx: *anyopaque,
    retain: ?*const fn (ctx: *anyopaque) void = null,
    release: ?*const fn (ctx: *anyopaque) void = null,
    name: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
    value: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8,
    visible_value: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8 = null,
    visible_range: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!terminal_text.OffsetRange = null,
    snapshot: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!TerminalSnapshot = null,
    focused: *const fn (ctx: *anyopaque) bool,
};

pub const TerminalSnapshot = struct {
    document_text: []u8,
    visible_text: []u8,
    visible_range: terminal_text.OffsetRange,
    caret_offset: usize = 0,
    geometry: ?TerminalRangeGeometry = null,
};

pub const TerminalRangeGeometry = struct {
    cell_for_byte: []terminal_text.TerminalCellPosition,
    viewport_rows: u32,
    viewport_columns: u32,
    cell_width: f64,
    cell_height: f64,
    origin_x: f64,
    origin_y: f64,
};

pub const PaletteListProvider = struct {
    base: com.IRawElementProviderSimple,
    fragment: com.IRawElementProviderFragment,
    fragment_root: com.IRawElementProviderFragmentRoot,
    selection_iface: com.ISelectionProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state: PaletteListState,
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),

    const vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = PaletteListProvider.QueryInterface,
        .AddRef = PaletteListProvider.AddRef,
        .Release = PaletteListProvider.Release,
        .get_ProviderOptions = PaletteListProvider.get_ProviderOptions,
        .GetPatternProvider = PaletteListProvider.GetPatternProvider,
        .GetPropertyValue = PaletteListProvider.GetPropertyValue,
        .get_HostRawElementProvider = PaletteListProvider.get_HostRawElementProvider,
    };

    const fragment_vtbl: com.IRawElementProviderFragmentVtbl = .{
        .QueryInterface = FragmentQueryInterface,
        .AddRef = FragmentAddRef,
        .Release = FragmentRelease,
        .Navigate = FragmentNavigate,
        .GetRuntimeId = FragmentGetRuntimeId,
        .get_BoundingRectangle = FragmentGetBoundingRectangle,
        .GetEmbeddedFragmentRoots = FragmentGetEmbeddedFragmentRoots,
        .SetFocus = FragmentSetFocus,
        .get_FragmentRoot = FragmentGetFragmentRoot,
    };

    const fragment_root_vtbl: com.IRawElementProviderFragmentRootVtbl = .{
        .QueryInterface = FragmentRootQueryInterface,
        .AddRef = FragmentRootAddRef,
        .Release = FragmentRootRelease,
        .ElementProviderFromPoint = FragmentRootElementProviderFromPoint,
        .GetFocus = FragmentRootGetFocus,
    };

    const selection_vtbl: com.ISelectionProviderVtbl = .{
        .QueryInterface = SelectionQueryInterface,
        .AddRef = SelectionAddRef,
        .Release = SelectionRelease,
        .GetSelection = SelectionGetSelection,
        .get_CanSelectMultiple = SelectionGetCanSelectMultiple,
        .get_IsSelectionRequired = SelectionGetIsSelectionRequired,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        state: PaletteListState,
    ) !*PaletteListProvider {
        const self = try alloc.create(PaletteListProvider);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .fragment = .{ .vtbl = &fragment_vtbl },
            .fragment_root = .{ .vtbl = &fragment_root_vtbl },
            .selection_iface = .{ .vtbl = &selection_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .state = state,
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Disconnect from the widget before its owner is freed. UIA clients may
    /// retain COM references beyond HWND teardown.
    pub fn detach(self: *PaletteListProvider) void {
        self.detached.store(true, .release);
    }

    pub fn disconnect(self: *PaletteListProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        const hr = com.UiaDisconnectProvider(&self.base);
        if (hr == com.S_OK) {
            self.disconnected.store(true, .release);
        }
        return hr;
    }

    /// Raise the item-level selection event for a row after the owner has
    /// updated its live selected-index state. The row exists only for the
    /// duration of the raise; UIA retains it if a client needs it longer.
    pub fn raiseSelectionChanged(self: *PaletteListProvider, index: usize) void {
        if (com.UiaClientsAreListening() == 0) return;
        const row = self.createRow(index) orelse return;
        defer _ = PaletteRowProvider.Release(&row.base);
        const hr = com.UiaRaiseAutomationEvent(
            &row.base,
            constants.UIA_SelectionItem_ElementSelectedEventId,
        );
        if (hr < 0) std.log.warn("uia: palette row selection event failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *PaletteListProvider {
        return @fieldParentPtr("base", p);
    }

    fn fromFragmentRoot(p: *com.IRawElementProviderFragmentRoot) *PaletteListProvider {
        return @fieldParentPtr("fragment_root", p);
    }

    fn fromFragment(p: *com.IRawElementProviderFragment) *PaletteListProvider {
        return @fieldParentPtr("fragment", p);
    }

    fn fromSelection(p: *com.ISelectionProvider) *PaletteListProvider {
        return @fieldParentPtr("selection_iface", p);
    }

    fn isAvailable(self: *const PaletteListProvider) bool {
        return !self.detached.load(.acquire);
    }

    fn rowCount(self: *const PaletteListProvider) usize {
        if (!self.isAvailable()) return 0;
        const callback = self.state.row_count orelse return 0;
        return callback(self.state.ctx);
    }

    fn selectedIndex(self: *const PaletteListProvider) ?usize {
        if (!self.isAvailable()) return null;
        const callback = self.state.selected_index orelse return null;
        const index = callback(self.state.ctx) orelse return null;
        return if (index < self.rowCount()) index else null;
    }

    fn createRow(self: *PaletteListProvider, index: usize) ?*PaletteRowProvider {
        if (index >= self.rowCount()) return null;
        return PaletteRowProvider.create(self.alloc, self, index, self.rowId(index)) catch null;
    }

    fn rowId(self: *const PaletteListProvider, index: usize) u64 {
        const callback = self.state.row_id orelse return index + 1;
        return callback(self.state.ctx, index);
    }

    fn geometry(self: *const PaletteListProvider) ?PaletteListGeometry {
        if (!self.isAvailable()) return null;
        const callback = self.state.geometry orelse return null;
        const value = callback(self.state.ctx) orelse return null;
        if (value.bounds.width <= 0 or value.bounds.height <= 0 or value.row_height <= 0) return null;
        return value;
    }

    fn rowBounds(self: *const PaletteListProvider, index: usize) ?com.UiaRect {
        const snapshot = self.geometry() orelse return null;
        if (index < snapshot.first_visible or index >= snapshot.first_visible + snapshot.visible_count) return null;
        const offset: f64 = @floatFromInt(index - snapshot.first_visible);
        const top = snapshot.bounds.top + offset * snapshot.row_height;
        const remaining = snapshot.bounds.top + snapshot.bounds.height - top;
        if (remaining <= 0) return null;
        return .{
            .left = snapshot.bounds.left,
            .top = top,
            .width = snapshot.bounds.width,
            .height = @min(snapshot.row_height, remaining),
        };
    }

    fn rowEnabled(self: *const PaletteListProvider, index: usize) bool {
        if (index >= self.rowCount()) return false;
        const callback = self.state.row_enabled orelse return true;
        return callback(self.state.ctx, index);
    }

    pub fn QueryInterface(
        self_base: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        if (iidEqual(iid, &com.IID_IRawElementProviderFragmentRoot)) {
            out.* = @ptrCast(&self.fragment_root);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        if (iidEqual(iid, &com.IID_IRawElementProviderFragment)) {
            out.* = @ptrCast(&self.fragment);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        if (iidEqual(iid, &com.IID_ISelectionProvider)) {
            out.* = @ptrCast(&self.selection_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        return com.E_NOINTERFACE;
    }

    pub fn AddRef(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    pub fn Release(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            self.alloc.destroy(self);
            return 0;
        }
        return prev - 1;
    }

    fn get_ProviderOptions(
        _: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider;
        return com.S_OK;
    }

    fn GetPatternProvider(
        self_base: *com.IRawElementProviderSimple,
        pattern_id: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (!self.isAvailable()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (pattern_id == constants.UIA_SelectionPatternId) {
            out.* = @ptrCast(&self.selection_iface);
            _ = AddRef(&self.base);
        }
        return com.S_OK;
    }

    fn SelectionQueryInterface(
        self_selection: *com.ISelectionProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromSelection(self_selection).base, iid, out);
    }

    fn SelectionAddRef(self_selection: *com.ISelectionProvider) callconv(.winapi) u32 {
        return AddRef(&fromSelection(self_selection).base);
    }

    fn SelectionRelease(self_selection: *com.ISelectionProvider) callconv(.winapi) u32 {
        return Release(&fromSelection(self_selection).base);
    }

    fn SelectionGetSelection(
        self_selection: *com.ISelectionProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromSelection(self_selection);
        out.* = null;
        if (!self.isAvailable()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const selected = self.selectedIndex();
        const array = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, if (selected == null) 0 else 1) orelse
            return com.E_OUTOFMEMORY;
        if (selected) |index| {
            const row = self.createRow(index) orelse {
                _ = com.SafeArrayDestroy(array);
                return com.E_OUTOFMEMORY;
            };
            defer _ = PaletteRowProvider.Release(&row.base);
            var array_index: i32 = 0;
            if (com.SafeArrayPutElement(array, &array_index, @ptrCast(&row.base)) != com.S_OK) {
                _ = com.SafeArrayDestroy(array);
                return com.E_OUTOFMEMORY;
            }
        }
        out.* = array;
        return com.S_OK;
    }

    fn SelectionGetCanSelectMultiple(
        self_selection: *com.ISelectionProvider,
        out: *com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        out.* = 0;
        if (!fromSelection(self_selection).isAvailable()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.S_OK;
    }

    fn SelectionGetIsSelectionRequired(
        self_selection: *com.ISelectionProvider,
        out: *com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        out.* = 0;
        const self = fromSelection(self_selection);
        if (!self.isAvailable()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = if (self.rowCount() > 0) 1 else 0;
        return com.S_OK;
    }

    fn GetPropertyValue(
        self_base: *com.IRawElementProviderSimple,
        prop_id: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = com.VARIANT.empty();
        if (self.detached.load(.acquire)) return @bitCast(@as(u32, 0x80040201));

        switch (prop_id) {
            constants.UIA_ControlTypePropertyId => {
                out.* = com.VARIANT.fromI4(constants.UIA_ListControlTypeId);
            },
            constants.UIA_NamePropertyId => {
                // Live query — the name reflects the current selection
                // so clients hear it via NameChanged events (raised
                // from `Host.moveListSelection`).
                var buf: [256]u8 = undefined;
                const text = self.state.name(self.state.ctx, &buf);
                const bstr = allocBstrFromUtf8(self.alloc, text) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_LocalizedControlTypePropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("command palette matches");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            constants.UIA_IsEnabledPropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_IsKeyboardFocusablePropertyId => out.* = com.VARIANT.fromBool(false),
            constants.UIA_HasKeyboardFocusPropertyId => {
                // The EDIT sibling actually owns focus; the list
                // announces selection via NameChanged instead.
                out.* = com.VARIANT.fromBool(false);
            },
            else => {},
        }
        return com.S_OK;
    }

    fn get_HostRawElementProvider(
        self_base: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        if (self.detached.load(.acquire)) {
            out.* = null;
            return @bitCast(@as(u32, 0x80040201));
        }
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }

    fn FragmentQueryInterface(
        self_fragment: *com.IRawElementProviderFragment,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromFragment(self_fragment).base, iid, out);
    }

    fn FragmentAddRef(self_fragment: *com.IRawElementProviderFragment) callconv(.winapi) u32 {
        return AddRef(&fromFragment(self_fragment).base);
    }

    fn FragmentRelease(self_fragment: *com.IRawElementProviderFragment) callconv(.winapi) u32 {
        return Release(&fromFragment(self_fragment).base);
    }

    fn FragmentRootQueryInterface(
        self_root: *com.IRawElementProviderFragmentRoot,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromFragmentRoot(self_root).base, iid, out);
    }

    fn FragmentRootAddRef(self_root: *com.IRawElementProviderFragmentRoot) callconv(.winapi) u32 {
        return AddRef(&fromFragmentRoot(self_root).base);
    }

    fn FragmentRootRelease(self_root: *com.IRawElementProviderFragmentRoot) callconv(.winapi) u32 {
        return Release(&fromFragmentRoot(self_root).base);
    }

    fn FragmentNavigate(
        self_fragment: *com.IRawElementProviderFragment,
        direction: i32,
        out: *?*com.IRawElementProviderFragment,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(self_fragment);
        out.* = null;
        const count = self.rowCount();
        if (count == 0) return com.S_OK;
        const index = switch (direction) {
            com.NavigateDirection_FirstChild => 0,
            com.NavigateDirection_LastChild => count - 1,
            else => return com.S_OK,
        };
        const row = self.createRow(index) orelse return com.E_OUTOFMEMORY;
        out.* = &row.fragment;
        return com.S_OK;
    }

    fn FragmentGetRuntimeId(
        _: *com.IRawElementProviderFragment,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }

    fn FragmentGetBoundingRectangle(
        self_fragment: *com.IRawElementProviderFragment,
        out: *com.UiaRect,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(self_fragment);
        if (!self.isAvailable()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = if (self.geometry()) |value| value.bounds else .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        return com.S_OK;
    }

    fn FragmentGetEmbeddedFragmentRoots(
        _: *com.IRawElementProviderFragment,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }

    fn FragmentSetFocus(_: *com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        return com.E_NOTIMPL;
    }

    fn FragmentGetFragmentRoot(
        self_fragment: *com.IRawElementProviderFragment,
        out: *?*com.IRawElementProviderFragmentRoot,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(self_fragment);
        out.* = &self.fragment_root;
        _ = AddRef(&self.base);
        return com.S_OK;
    }

    fn FragmentRootElementProviderFromPoint(
        self_root: *com.IRawElementProviderFragmentRoot,
        x: f64,
        y: f64,
        out: *?*com.IRawElementProviderFragment,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        const self = fromFragmentRoot(self_root);
        if (!self.isAvailable()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return com.S_OK;
        const snapshot = self.geometry() orelse return com.S_OK;
        if (x < snapshot.bounds.left or x >= snapshot.bounds.left + snapshot.bounds.width or
            y < snapshot.bounds.top or y >= snapshot.bounds.top + snapshot.bounds.height)
        {
            return com.S_OK;
        }
        const offset: usize = @intFromFloat(@floor((y - snapshot.bounds.top) / snapshot.row_height));
        if (offset >= snapshot.visible_count) return com.S_OK;
        const index = snapshot.first_visible + offset;
        const row = self.createRow(index) orelse return com.S_OK;
        out.* = &row.fragment;
        return com.S_OK;
    }

    fn FragmentRootGetFocus(
        self_root: *com.IRawElementProviderFragmentRoot,
        out: *?*com.IRawElementProviderFragment,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragmentRoot(self_root);
        out.* = null;
        return if (self.isAvailable()) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
    }
};

const PaletteRowProvider = struct {
    base: com.IRawElementProviderSimple,
    fragment: com.IRawElementProviderFragment,
    selection_item: com.ISelectionItemProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    parent: *PaletteListProvider,
    index: usize,
    id: u64,

    const simple_vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .get_ProviderOptions = getProviderOptions,
        .GetPatternProvider = GetPatternProvider,
        .GetPropertyValue = GetPropertyValue,
        .get_HostRawElementProvider = getHostRawElementProvider,
    };
    const fragment_vtbl: com.IRawElementProviderFragmentVtbl = .{
        .QueryInterface = FragmentQueryInterface,
        .AddRef = FragmentAddRef,
        .Release = FragmentRelease,
        .Navigate = Navigate,
        .GetRuntimeId = GetRuntimeId,
        .get_BoundingRectangle = GetBoundingRectangle,
        .GetEmbeddedFragmentRoots = GetEmbeddedFragmentRoots,
        .SetFocus = SetFocus,
        .get_FragmentRoot = GetFragmentRoot,
    };
    const selection_vtbl: com.ISelectionItemProviderVtbl = .{
        .QueryInterface = SelectionQueryInterface,
        .AddRef = SelectionAddRef,
        .Release = SelectionRelease,
        .Select = Select,
        .AddToSelection = AddToSelection,
        .RemoveFromSelection = RemoveFromSelection,
        .get_IsSelected = GetIsSelected,
        .get_SelectionContainer = GetSelectionContainer,
    };

    fn create(alloc: std.mem.Allocator, parent: *PaletteListProvider, index: usize, id: u64) !*PaletteRowProvider {
        const self = try alloc.create(PaletteRowProvider);
        _ = PaletteListProvider.AddRef(&parent.base);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .fragment = .{ .vtbl = &fragment_vtbl },
            .selection_item = .{ .vtbl = &selection_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .parent = parent,
            .index = index,
            .id = id,
        };
        return self;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *PaletteRowProvider {
        return @fieldParentPtr("base", p);
    }
    fn fromFragment(p: *com.IRawElementProviderFragment) *PaletteRowProvider {
        return @fieldParentPtr("fragment", p);
    }
    fn fromSelection(p: *com.ISelectionItemProvider) *PaletteRowProvider {
        return @fieldParentPtr("selection_item", p);
    }
    fn available(self: *const PaletteRowProvider) bool {
        return self.parent.isAvailable() and
            self.index < self.parent.rowCount() and
            self.parent.rowId(self.index) == self.id;
    }

    fn query(self: *PaletteRowProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or iidEqual(iid, &com.IID_IRawElementProviderSimple)) out.* = @ptrCast(&self.base) else if (iidEqual(iid, &com.IID_IRawElementProviderFragment)) out.* = @ptrCast(&self.fragment) else if (iidEqual(iid, &com.IID_ISelectionItemProvider)) out.* = @ptrCast(&self.selection_item) else return com.E_NOINTERFACE;
        _ = self.refcount.fetchAdd(1, .monotonic);
        return com.S_OK;
    }
    fn QueryInterface(p: *com.IRawElementProviderSimple, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return fromBase(p).query(iid, out);
    }
    fn FragmentQueryInterface(p: *com.IRawElementProviderFragment, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return fromFragment(p).query(iid, out);
    }
    fn SelectionQueryInterface(p: *com.ISelectionItemProvider, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return fromSelection(p).query(iid, out);
    }
    fn addRef(self: *PaletteRowProvider) u32 {
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }
    fn AddRef(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(p).addRef();
    }
    fn FragmentAddRef(p: *com.IRawElementProviderFragment) callconv(.winapi) u32 {
        return fromFragment(p).addRef();
    }
    fn SelectionAddRef(p: *com.ISelectionItemProvider) callconv(.winapi) u32 {
        return fromSelection(p).addRef();
    }
    fn release(self: *PaletteRowProvider) u32 {
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            _ = PaletteListProvider.Release(&self.parent.base);
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }
    fn Release(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(p).release();
    }
    fn FragmentRelease(p: *com.IRawElementProviderFragment) callconv(.winapi) u32 {
        return fromFragment(p).release();
    }
    fn SelectionRelease(p: *com.ISelectionItemProvider) callconv(.winapi) u32 {
        return fromSelection(p).release();
    }
    fn getProviderOptions(_: *com.IRawElementProviderSimple, out: *i32) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider;
        return com.S_OK;
    }
    fn GetPatternProvider(p: *com.IRawElementProviderSimple, pattern: i32, out: *?*com.IUnknown) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (pattern == constants.UIA_SelectionItemPatternId) {
            out.* = @ptrCast(&self.selection_item);
            _ = self.addRef();
        }
        return com.S_OK;
    }
    fn GetPropertyValue(p: *com.IRawElementProviderSimple, property: i32, out: *com.VARIANT) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = com.VARIANT.empty();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        switch (property) {
            constants.UIA_ControlTypePropertyId => out.* = com.VARIANT.fromI4(constants.UIA_ListItemControlTypeId),
            constants.UIA_NamePropertyId => {
                var buf: [512]u8 = undefined;
                const callback = self.parent.state.row_name orelse return com.S_OK;
                const bstr = allocBstrFromUtf8(
                    self.alloc,
                    callback(self.parent.state.ctx, self.index, &buf),
                ) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_SelectionItemIsSelectedPropertyId => out.* = com.VARIANT.fromBool(self.parent.selectedIndex() == self.index),
            constants.UIA_IsOffscreenPropertyId => out.* = com.VARIANT.fromBool(self.parent.rowBounds(self.index) == null),
            constants.UIA_IsControlElementPropertyId, constants.UIA_IsContentElementPropertyId => out.* = com.VARIANT.fromBool(true),
            constants.UIA_IsEnabledPropertyId => out.* = com.VARIANT.fromBool(self.parent.rowEnabled(self.index)),
            else => {},
        }
        return com.S_OK;
    }
    fn getHostRawElementProvider(_: *com.IRawElementProviderSimple, out: *?*com.IRawElementProviderSimple) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }
    fn Navigate(p: *com.IRawElementProviderFragment, direction: i32, out: *?*com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (direction == com.NavigateDirection_Parent) {
            out.* = &self.parent.fragment;
            _ = PaletteListProvider.AddRef(&self.parent.base);
            return com.S_OK;
        }
        const next: ?usize = switch (direction) {
            com.NavigateDirection_NextSibling => if (self.index + 1 < self.parent.rowCount()) self.index + 1 else null,
            com.NavigateDirection_PreviousSibling => if (self.index > 0) self.index - 1 else null,
            else => null,
        };
        const index = next orelse return com.S_OK;
        const row = self.parent.createRow(index) orelse return com.E_OUTOFMEMORY;
        out.* = &row.fragment;
        return com.S_OK;
    }
    fn GetRuntimeId(p: *com.IRawElementProviderFragment, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const array = com.SafeArrayCreateVector(com.VT_I4, 0, 3) orelse return com.E_OUTOFMEMORY;
        var first: i32 = com.UiaAppendRuntimeId;
        var low: i32 = @bitCast(@as(u32, @truncate(self.id)));
        var high: i32 = @bitCast(@as(u32, @truncate(self.id >> 32)));
        var i: i32 = 0;
        if (com.SafeArrayPutElement(array, &i, &first) != com.S_OK) {
            _ = com.SafeArrayDestroy(array);
            return com.E_OUTOFMEMORY;
        }
        i = 1;
        if (com.SafeArrayPutElement(array, &i, &low) != com.S_OK) {
            _ = com.SafeArrayDestroy(array);
            return com.E_OUTOFMEMORY;
        }
        i = 2;
        if (com.SafeArrayPutElement(array, &i, &high) != com.S_OK) {
            _ = com.SafeArrayDestroy(array);
            return com.E_OUTOFMEMORY;
        }
        out.* = array;
        return com.S_OK;
    }
    fn GetBoundingRectangle(p: *com.IRawElementProviderFragment, out: *com.UiaRect) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = self.parent.rowBounds(self.index) orelse .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        return com.S_OK;
    }
    fn GetEmbeddedFragmentRoots(_: *com.IRawElementProviderFragment, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }
    fn SetFocus(p: *com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.parent.rowEnabled(self.index)) return com.UIA_E_ELEMENTNOTENABLED;
        return com.E_NOTIMPL;
    }
    fn GetFragmentRoot(p: *com.IRawElementProviderFragment, out: *?*com.IRawElementProviderFragmentRoot) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = &self.parent.fragment_root;
        _ = PaletteListProvider.AddRef(&self.parent.base);
        return com.S_OK;
    }
    fn select(self: *PaletteRowProvider) com.HRESULT {
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.parent.rowEnabled(self.index)) return com.UIA_E_ELEMENTNOTENABLED;
        const callback = self.parent.state.select_row orelse return com.S_OK;
        callback(self.parent.state.ctx, self.index);
        return com.S_OK;
    }
    fn Select(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        return fromSelection(p).select();
    }
    fn AddToSelection(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.parent.rowEnabled(self.index)) return com.UIA_E_ELEMENTNOTENABLED;
        return if (self.parent.selectedIndex() == self.index)
            com.S_OK
        else
            com.UIA_E_INVALIDOPERATION;
    }
    fn RemoveFromSelection(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.parent.rowEnabled(self.index)) return com.UIA_E_ELEMENTNOTENABLED;
        return if (self.parent.selectedIndex() == self.index)
            com.UIA_E_INVALIDOPERATION
        else
            com.S_OK;
    }
    fn GetIsSelected(p: *com.ISelectionItemProvider, out: *com.BOOL) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = if (self.parent.selectedIndex() == self.index) 1 else 0;
        return com.S_OK;
    }
    fn GetSelectionContainer(p: *com.ISelectionItemProvider, out: *?*com.IRawElementProviderSimple) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = &self.parent.base;
        _ = PaletteListProvider.AddRef(&self.parent.base);
        return com.S_OK;
    }
};

pub const TerminalProvider = struct {
    base: com.IRawElementProviderSimple,
    text_iface: com.ITextProvider,
    text2_iface: com.ITextProvider2,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state: TerminalState,
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),

    const simple_vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = TerminalProvider.QueryInterface,
        .AddRef = TerminalProvider.AddRef,
        .Release = TerminalProvider.Release,
        .get_ProviderOptions = TerminalProvider.get_ProviderOptions,
        .GetPatternProvider = TerminalProvider.GetPatternProvider,
        .GetPropertyValue = TerminalProvider.GetPropertyValue,
        .get_HostRawElementProvider = TerminalProvider.get_HostRawElementProvider,
    };

    const text_vtbl: com.ITextProviderVtbl = .{
        .QueryInterface = TerminalProvider.TextQueryInterface,
        .AddRef = TerminalProvider.TextAddRef,
        .Release = TerminalProvider.TextRelease,
        .GetSelection = TerminalProvider.GetSelection,
        .GetVisibleRanges = TerminalProvider.GetVisibleRanges,
        .RangeFromChild = TerminalProvider.RangeFromChild,
        .RangeFromPoint = TerminalProvider.RangeFromPoint,
        .get_DocumentRange = TerminalProvider.get_DocumentRange,
        .get_SupportedTextSelection = TerminalProvider.get_SupportedTextSelection,
    };

    const text2_vtbl: com.ITextProvider2Vtbl = .{
        .QueryInterface = TerminalProvider.Text2QueryInterface,
        .AddRef = TerminalProvider.Text2AddRef,
        .Release = TerminalProvider.Text2Release,
        .GetSelection = TerminalProvider.Text2GetSelection,
        .GetVisibleRanges = TerminalProvider.Text2GetVisibleRanges,
        .RangeFromChild = TerminalProvider.Text2RangeFromChild,
        .RangeFromPoint = TerminalProvider.Text2RangeFromPoint,
        .get_DocumentRange = TerminalProvider.Text2GetDocumentRange,
        .get_SupportedTextSelection = TerminalProvider.Text2GetSupportedTextSelection,
        .RangeFromAnnotation = TerminalProvider.RangeFromAnnotation,
        .GetCaretRange = TerminalProvider.GetCaretRange,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        state: TerminalState,
    ) !*TerminalProvider {
        const self = try alloc.create(TerminalProvider);
        if (state.retain) |retain| retain(state.ctx);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .text_iface = .{ .vtbl = &text_vtbl },
            .text2_iface = .{ .vtbl = &text2_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .state = state,
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Disconnect from the HWND before its owner is destroyed. UIA clients
    /// may retain COM references beyond terminal window teardown.
    pub fn detach(self: *TerminalProvider) void {
        self.detached.store(true, .release);
    }

    pub fn disconnect(self: *TerminalProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        const hr = com.UiaDisconnectProvider(&self.base);
        if (hr == com.S_OK) {
            self.disconnected.store(true, .release);
        }
        return hr;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *TerminalProvider {
        return @fieldParentPtr("base", p);
    }

    fn fromText(p: *com.ITextProvider) *TerminalProvider {
        return @fieldParentPtr("text_iface", p);
    }

    fn fromText2(p: *com.ITextProvider2) *TerminalProvider {
        return @fieldParentPtr("text2_iface", p);
    }

    pub fn QueryInterface(
        self_base: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        return self.queryInterface(iid, out);
    }

    fn TextQueryInterface(
        self_text: *com.ITextProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        const self = fromText(self_text);
        return self.queryInterface(iid, out);
    }

    fn Text2QueryInterface(
        self_text: *com.ITextProvider2,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromText2(self_text).queryInterface(iid, out);
    }

    fn queryInterface(
        self: *TerminalProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        if (iidEqual(iid, &com.IID_ITextProvider)) {
            out.* = @ptrCast(&self.text_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        if (iidEqual(iid, &com.IID_ITextProvider2)) {
            out.* = @ptrCast(&self.text2_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        return com.E_NOINTERFACE;
    }

    pub fn AddRef(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn TextAddRef(self_text: *com.ITextProvider) callconv(.winapi) u32 {
        const self = fromText(self_text);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Text2AddRef(self_text: *com.ITextProvider2) callconv(.winapi) u32 {
        return fromText2(self_text).refcount.fetchAdd(1, .monotonic) + 1;
    }

    pub fn Release(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        return self.release();
    }

    fn TextRelease(self_text: *com.ITextProvider) callconv(.winapi) u32 {
        const self = fromText(self_text);
        return self.release();
    }

    fn Text2Release(self_text: *com.ITextProvider2) callconv(.winapi) u32 {
        return fromText2(self_text).release();
    }

    fn release(self: *TerminalProvider) u32 {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            if (self.state.release) |release_state| release_state(self.state.ctx);
            self.alloc.destroy(self);
            return 0;
        }
        return prev - 1;
    }

    fn get_ProviderOptions(
        _: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider;
        return com.S_OK;
    }

    fn GetPatternProvider(
        self_base: *com.IRawElementProviderSimple,
        pattern_id: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (pattern_id == constants.UIA_TextPatternId) {
            out.* = @ptrCast(&self.text_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
        } else if (pattern_id == constants.UIA_TextPattern2Id) {
            out.* = @ptrCast(&self.text2_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
        }
        return com.S_OK;
    }

    fn GetPropertyValue(
        self_base: *com.IRawElementProviderSimple,
        prop_id: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = com.VARIANT.empty();
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;

        switch (prop_id) {
            constants.UIA_ControlTypePropertyId => {
                out.* = com.VARIANT.fromI4(constants.UIA_DocumentControlTypeId);
            },
            constants.UIA_NamePropertyId => {
                var buf: [256]u8 = undefined;
                const name = self.state.name(self.state.ctx, &buf);
                const bstr = allocBstrFromUtf8(self.alloc, name) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_LocalizedControlTypePropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("terminal");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_HelpTextPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Read-only terminal text");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            constants.UIA_IsEnabledPropertyId,
            constants.UIA_IsKeyboardFocusablePropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_HasKeyboardFocusPropertyId => {
                out.* = com.VARIANT.fromBool(self.state.focused(self.state.ctx));
            },
            else => {},
        }
        return com.S_OK;
    }

    fn get_HostRawElementProvider(
        self_base: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        if (self.detached.load(.acquire)) {
            out.* = null;
            return @bitCast(@as(u32, 0x80040201));
        }
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }

    fn GetSelection(
        self_text: *com.ITextProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        const self = fromText(self_text);
        return if (self.detached.load(.acquire))
            com.UIA_E_ELEMENTNOTAVAILABLE
        else
            com.S_OK;
    }

    fn GetVisibleRanges(
        self_text: *com.ITextProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromText(self_text);
        return self.singleVisibleRangeArray(out);
    }

    fn RangeFromChild(
        self_text: *com.ITextProvider,
        _: ?*com.IRawElementProviderSimple,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        if (fromText(self_text).detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.E_NOTIMPL;
    }

    fn RangeFromPoint(
        self_text: *com.ITextProvider,
        point: com.UiaPoint,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        const self = fromText(self_text);
        return self.createRangeFromPoint(point, out);
    }

    fn get_DocumentRange(
        self_text: *com.ITextProvider,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        const self = fromText(self_text);
        return self.createDocumentRange(out);
    }

    fn get_SupportedTextSelection(
        self_text: *com.ITextProvider,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.SupportedTextSelection_None;
        if (fromText(self_text).detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.S_OK;
    }

    fn Text2GetSelection(self_text: *com.ITextProvider2, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        return GetSelection(&fromText2(self_text).text_iface, out);
    }

    fn Text2GetVisibleRanges(self_text: *com.ITextProvider2, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        return GetVisibleRanges(&fromText2(self_text).text_iface, out);
    }

    fn Text2RangeFromChild(
        self_text: *com.ITextProvider2,
        child: ?*com.IRawElementProviderSimple,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        return RangeFromChild(&fromText2(self_text).text_iface, child, out);
    }

    fn Text2RangeFromPoint(
        self_text: *com.ITextProvider2,
        point: com.UiaPoint,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        return RangeFromPoint(&fromText2(self_text).text_iface, point, out);
    }

    fn Text2GetDocumentRange(
        self_text: *com.ITextProvider2,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        return get_DocumentRange(&fromText2(self_text).text_iface, out);
    }

    fn Text2GetSupportedTextSelection(
        self_text: *com.ITextProvider2,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        return get_SupportedTextSelection(&fromText2(self_text).text_iface, out);
    }

    fn RangeFromAnnotation(
        self_text: *com.ITextProvider2,
        _: ?*com.IRawElementProviderSimple,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        if (fromText2(self_text).detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.E_NOTIMPL;
    }

    fn GetCaretRange(
        self_text: *com.ITextProvider2,
        is_active: *com.BOOL,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        const self = fromText2(self_text);
        is_active.* = 0;
        out.* = null;
        var terminal_snapshot = self.terminalSnapshot() catch |err| return switch (err) {
            error.ElementNotAvailable => com.UIA_E_ELEMENTNOTAVAILABLE,
            else => com.E_OUTOFMEMORY,
        };
        defer self.alloc.free(terminal_snapshot.visible_text);

        is_active.* = if (self.state.focused(self.state.ctx)) 1 else 0;
        return self.createRangeFromSnapshot(
            &terminal_snapshot,
            .{
                .start = terminal_snapshot.caret_offset,
                .end = terminal_snapshot.caret_offset,
            },
            out,
        );
    }

    /// UI-thread event hook used after the owning terminal publishes a new
    /// immutable snapshot.
    pub fn raiseTextChanged(self: *TerminalProvider) void {
        if (self.detached.load(.acquire)) return;
        @import("events.zig").raiseTextChanged(&self.base);
    }

    pub fn raiseTextSelectionChanged(self: *TerminalProvider) void {
        if (self.detached.load(.acquire)) return;
        @import("events.zig").raiseTextSelectionChanged(&self.base);
    }

    fn singleVisibleRangeArray(self: *TerminalProvider, out: *?*com.SAFEARRAY) com.HRESULT {
        out.* = null;
        var range: ?*com.ITextRangeProvider = null;
        const range_hr = self.createVisibleRange(&range);
        if (range_hr != com.S_OK) return range_hr;
        defer _ = TerminalTextRangeProvider.Release(range.?);

        const array = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, 1) orelse return com.E_OUTOFMEMORY;

        var index: i32 = 0;
        const put_hr = com.SafeArrayPutElement(array, &index, @ptrCast(range.?));
        if (put_hr != com.S_OK) {
            _ = com.SafeArrayDestroy(array);
            return put_hr;
        }

        out.* = array;
        return com.S_OK;
    }

    fn createVisibleRange(
        self: *TerminalProvider,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        out.* = null;
        var terminal_snapshot = self.terminalSnapshot() catch |err| return switch (err) {
            error.ElementNotAvailable => com.UIA_E_ELEMENTNOTAVAILABLE,
            else => com.E_OUTOFMEMORY,
        };
        defer self.alloc.free(terminal_snapshot.visible_text);
        return self.createRangeFromSnapshot(&terminal_snapshot, terminal_snapshot.visible_range, out);
    }

    fn createDocumentRange(
        self: *TerminalProvider,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        out.* = null;
        var terminal_snapshot = self.terminalSnapshot() catch |err| return switch (err) {
            error.ElementNotAvailable => com.UIA_E_ELEMENTNOTAVAILABLE,
            else => com.E_OUTOFMEMORY,
        };
        defer self.alloc.free(terminal_snapshot.visible_text);
        return self.createRangeFromSnapshot(
            &terminal_snapshot,
            .{ .start = 0, .end = terminal_snapshot.document_text.len },
            out,
        );
    }

    fn createRange(
        self: *TerminalProvider,
        range_offsets: terminal_text.OffsetRange,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        out.* = null;
        const text = self.state.value(self.state.ctx, self.alloc) catch |err| {
            std.log.warn("uia: TerminalProvider text snapshot failed err={}", .{err});
            return com.E_OUTOFMEMORY;
        };

        return self.createRangeFromText(text, range_offsets, out);
    }

    fn createRangeFromPoint(
        self: *TerminalProvider,
        point: com.UiaPoint,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        out.* = null;
        var terminal_snapshot = self.terminalSnapshot() catch |err| return switch (err) {
            error.ElementNotAvailable => com.UIA_E_ELEMENTNOTAVAILABLE,
            else => com.E_OUTOFMEMORY,
        };
        defer self.alloc.free(terminal_snapshot.visible_text);

        const document_offset = self.byteOffsetForScreenPoint(&terminal_snapshot, point);
        return self.createRangeFromSnapshot(
            &terminal_snapshot,
            .{ .start = document_offset, .end = document_offset },
            out,
        );
    }

    fn visibleText(self: *TerminalProvider) ![]u8 {
        const value_fn = self.state.visible_value orelse self.state.value;
        return value_fn(self.state.ctx, self.alloc) catch |err| {
            std.log.warn("uia: TerminalProvider visible text snapshot failed err={}", .{err});
            return err;
        };
    }

    fn terminalSnapshot(self: *TerminalProvider) !TerminalSnapshot {
        if (self.detached.load(.acquire)) return error.ElementNotAvailable;
        const raw_snapshot = if (self.state.snapshot) |snapshot_fn| snapshot: {
            break :snapshot try snapshot_fn(self.state.ctx, self.alloc);
        } else snapshot: {
            const document_text = try self.state.value(self.state.ctx, self.alloc);
            errdefer self.alloc.free(document_text);

            const visible_text = try self.alloc.dupe(u8, document_text);
            break :snapshot TerminalSnapshot{
                .document_text = document_text,
                .visible_text = visible_text,
                .visible_range = .{ .start = 0, .end = document_text.len },
                .caret_offset = document_text.len,
            };
        };

        errdefer self.alloc.free(raw_snapshot.document_text);
        errdefer self.alloc.free(raw_snapshot.visible_text);
        errdefer if (raw_snapshot.geometry) |geometry| self.alloc.free(geometry.cell_for_byte);

        const start = @min(raw_snapshot.visible_range.start, raw_snapshot.document_text.len);
        const end = @min(@max(start, raw_snapshot.visible_range.end), raw_snapshot.document_text.len);
        const caret_offset = utf8BoundaryAtOrBefore(
            raw_snapshot.document_text,
            @min(raw_snapshot.caret_offset, raw_snapshot.document_text.len),
        );
        return .{
            .document_text = raw_snapshot.document_text,
            .visible_text = raw_snapshot.visible_text,
            .visible_range = .{ .start = start, .end = end },
            .caret_offset = caret_offset,
            .geometry = raw_snapshot.geometry,
        };
    }

    fn byteOffsetForScreenPoint(self: *TerminalProvider, snapshot: *const TerminalSnapshot, point: com.UiaPoint) usize {
        const x = safeI32FromUiaCoord(point.x) orelse return 0;
        const y = safeI32FromUiaCoord(point.y) orelse return 0;
        var client_point = POINT{
            .x = x,
            .y = y,
        };
        var client_rect: RECT = undefined;
        if (ScreenToClient(self.hwnd, &client_point) == 0 or
            GetClientRect(self.hwnd, &client_rect) == 0)
        {
            return snapshot.visible_range.start;
        }

        if (snapshot.geometry) |geometry| {
            return byteOffsetForTerminalGridPoint(
                snapshot.document_text,
                snapshot.visible_range,
                geometry,
                client_point,
            );
        }

        const visible_offset = byteOffsetForClientPoint(snapshot.visible_text, client_rect, client_point);
        return visibleOffsetToDocumentOffset(snapshot.document_text, snapshot.visible_range, visible_offset);
    }

    fn createRangeFromText(
        self: *TerminalProvider,
        text: []u8,
        range_offsets: terminal_text.OffsetRange,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        const range = TerminalTextRangeProvider.createOwned(
            self.alloc,
            self,
            text,
            range_offsets,
        ) catch |err| {
            std.log.warn("uia: TerminalTextRangeProvider.create failed err={}", .{err});
            return com.E_OUTOFMEMORY;
        };
        out.* = &range.base;
        return com.S_OK;
    }

    fn createRangeFromSnapshot(
        self: *TerminalProvider,
        snapshot: *TerminalSnapshot,
        range_offsets: terminal_text.OffsetRange,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        const text = snapshot.document_text;
        const geometry = snapshot.geometry;
        snapshot.document_text = snapshot.document_text[0..0];
        snapshot.geometry = null;

        const range = TerminalTextRangeProvider.createOwnedWithGeometry(
            self.alloc,
            self,
            text,
            range_offsets,
            geometry,
        ) catch |err| {
            std.log.warn("uia: TerminalTextRangeProvider.create failed err={}", .{err});
            return com.E_OUTOFMEMORY;
        };
        out.* = &range.base;
        return com.S_OK;
    }
};

const TerminalTextRangeProvider = struct {
    base: com.ITextRangeProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    parent: *TerminalProvider,
    snapshot: *Snapshot,
    text: []u8,
    range: terminal_text.OffsetRange,
    geometry: ?TerminalRangeGeometry,

    /// Immutable backing shared by clones and FindText results. UIA clients
    /// routinely clone ranges while walking a document; sharing avoids copying
    /// the bounded terminal document and its per-byte geometry on every step.
    const Snapshot = struct {
        refcount: std.atomic.Value(u32),
        alloc: std.mem.Allocator,
        text: []u8,
        geometry: ?TerminalRangeGeometry,

        /// Consumes `text` and `geometry` on every outcome.
        fn createOwned(
            alloc: std.mem.Allocator,
            text: []u8,
            geometry: ?TerminalRangeGeometry,
        ) !*Snapshot {
            errdefer {
                if (geometry) |value| alloc.free(value.cell_for_byte);
                alloc.free(text);
            }
            const self = try alloc.create(Snapshot);
            self.* = .{
                .refcount = std.atomic.Value(u32).init(1),
                .alloc = alloc,
                .text = text,
                .geometry = geometry,
            };
            return self;
        }

        fn retain(self: *Snapshot) void {
            _ = self.refcount.fetchAdd(1, .monotonic);
        }

        fn release(self: *Snapshot) void {
            if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
            if (self.geometry) |geometry| self.alloc.free(geometry.cell_for_byte);
            self.alloc.free(self.text);
            self.alloc.destroy(self);
        }
    };

    const vtbl: com.ITextRangeProviderVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .Clone = Clone,
        .Compare = Compare,
        .CompareEndpoints = CompareEndpoints,
        .ExpandToEnclosingUnit = ExpandToEnclosingUnit,
        .FindAttribute = FindAttribute,
        .FindText = FindText,
        .GetAttributeValue = GetAttributeValue,
        .GetBoundingRectangles = GetBoundingRectangles,
        .GetEnclosingElement = GetEnclosingElement,
        .GetText = GetText,
        .Move = Move,
        .MoveEndpointByUnit = MoveEndpointByUnit,
        .MoveEndpointByRange = MoveEndpointByRange,
        .Select = Select,
        .AddToSelection = AddToSelection,
        .RemoveFromSelection = RemoveFromSelection,
        .ScrollIntoView = ScrollIntoView,
        .GetChildren = GetChildren,
    };

    /// Consumes `text` on every outcome.
    fn createOwned(
        alloc: std.mem.Allocator,
        parent: *TerminalProvider,
        text: []u8,
        range: terminal_text.OffsetRange,
    ) !*TerminalTextRangeProvider {
        return createOwnedWithGeometry(alloc, parent, text, range, null);
    }

    /// Consumes `text` and `geometry` on every outcome.
    fn createOwnedWithGeometry(
        alloc: std.mem.Allocator,
        parent: *TerminalProvider,
        text: []u8,
        range: terminal_text.OffsetRange,
        geometry: ?TerminalRangeGeometry,
    ) !*TerminalTextRangeProvider {
        const snapshot = try Snapshot.createOwned(alloc, text, geometry);
        return createOwnedWithSnapshot(alloc, parent, snapshot, range);
    }

    /// Consumes one owned or retained `snapshot` reference on every outcome.
    fn createOwnedWithSnapshot(
        alloc: std.mem.Allocator,
        parent: *TerminalProvider,
        snapshot: *Snapshot,
        range: terminal_text.OffsetRange,
    ) !*TerminalTextRangeProvider {
        errdefer snapshot.release();
        const self = try alloc.create(TerminalTextRangeProvider);
        _ = TerminalProvider.AddRef(&parent.base);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .parent = parent,
            .snapshot = snapshot,
            .text = snapshot.text,
            .range = normalizeRange(range, snapshot.text.len),
            .geometry = snapshot.geometry,
        };
        return self;
    }

    fn fromBase(p: *com.ITextRangeProvider) *TerminalTextRangeProvider {
        return @fieldParentPtr("base", p);
    }

    fn normalizeRange(range: terminal_text.OffsetRange, text_len: usize) terminal_text.OffsetRange {
        const start = @min(range.start, text_len);
        const end = @min(@max(range.end, start), text_len);
        return .{ .start = start, .end = end };
    }

    fn QueryInterface(
        self_base: *com.ITextRangeProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_ITextRangeProvider))
        {
            out.* = @ptrCast(&self.base);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        return com.E_NOINTERFACE;
    }

    fn AddRef(self_base: *com.ITextRangeProvider) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn Release(self_base: *com.ITextRangeProvider) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            self.snapshot.release();
            _ = TerminalProvider.Release(&self.parent.base);
            self.alloc.destroy(self);
            return 0;
        }
        return prev - 1;
    }

    fn Clone(
        self_base: *com.ITextRangeProvider,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        self.snapshot.retain();
        const clone = createOwnedWithSnapshot(self.alloc, self.parent, self.snapshot, self.range) catch {
            return com.E_OUTOFMEMORY;
        };
        out.* = &clone.base;
        return com.S_OK;
    }

    fn Compare(
        self_base: *com.ITextRangeProvider,
        other: ?*com.ITextRangeProvider,
        out: *com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = 0;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const other_range = other orelse return com.S_OK;
        if (other_range.vtbl != &vtbl) return com.S_OK;
        const rhs = fromBase(other_range);
        out.* = if (self.parent == rhs.parent and
            self.range.start == rhs.range.start and
            self.range.end == rhs.range.end) 1 else 0;
        return com.S_OK;
    }

    fn CompareEndpoints(
        self_base: *com.ITextRangeProvider,
        endpoint: i32,
        other: ?*com.ITextRangeProvider,
        target_endpoint: i32,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = 0;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!validEndpoint(endpoint) or !validEndpoint(target_endpoint)) return com.E_INVALIDARG;
        const other_range = other orelse return com.E_POINTER;
        if (other_range.vtbl != &vtbl) return com.E_INVALIDARG;
        const rhs = fromBase(other_range);
        if (self.parent != rhs.parent) return com.E_INVALIDARG;
        const lhs_value = if (endpoint == com.TextPatternRangeEndpoint_End) self.range.end else self.range.start;
        const rhs_value = if (target_endpoint == com.TextPatternRangeEndpoint_End) rhs.range.end else rhs.range.start;
        out.* = if (lhs_value < rhs_value) -1 else if (lhs_value > rhs_value) 1 else 0;
        return com.S_OK;
    }

    fn ExpandToEnclosingUnit(
        self_base: *com.ITextRangeProvider,
        unit: i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const effective_unit = supportedTextUnit(unit) orelse return com.E_INVALIDARG;
        self.range = textUnitRange(self.text, effective_unit, self.range.start);
        return com.S_OK;
    }

    fn FindAttribute(
        self_base: *com.ITextRangeProvider,
        _: i32,
        _: com.VARIANT,
        _: com.BOOL,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        if (fromBase(self_base).parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.S_OK;
    }

    fn FindText(
        self_base: *com.ITextRangeProvider,
        value_w: ?[*]const u16,
        backward: com.BOOL,
        ignore_case: com.BOOL,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        const self = fromBase(self_base);
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const value_ptr = value_w orelse return com.E_POINTER;
        const value_len: usize = @intCast(com.SysStringLen(value_ptr));
        const needle = std.unicode.utf16LeToUtf8Alloc(self.alloc, value_ptr[0..value_len]) catch |err|
            return if (err == error.OutOfMemory) com.E_OUTOFMEMORY else com.E_INVALIDARG;
        defer self.alloc.free(needle);
        if (needle.len == 0) return com.S_OK;

        const normalized = normalizeRange(self.range, self.text.len);
        const haystack = self.text[normalized.start..normalized.end];
        const relative_range = if (ignore_case != 0)
            findTextRangeIgnoreCase(self.alloc, haystack, value_ptr[0..value_len], backward != 0) catch |err|
                return if (err == error.OutOfMemory) com.E_OUTOFMEMORY else com.E_INVALIDARG
        else exact: {
            const relative = findTextIndex(haystack, needle, backward != 0) orelse return com.S_OK;
            break :exact terminal_text.OffsetRange{
                .start = relative,
                .end = relative + needle.len,
            };
        };
        if (relative_range == null) return com.S_OK;
        const relative = relative_range.?;
        self.snapshot.retain();
        const match = createOwnedWithSnapshot(
            self.alloc,
            self.parent,
            self.snapshot,
            .{
                .start = normalized.start + relative.start,
                .end = normalized.start + relative.end,
            },
        ) catch return com.E_OUTOFMEMORY;
        out.* = &match.base;
        return com.S_OK;
    }

    fn GetAttributeValue(
        self_base: *com.ITextRangeProvider,
        _: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.VARIANT.empty();
        if (fromBase(self_base).parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        var not_supported: ?*com.IUnknown = null;
        const hr = com.UiaGetReservedNotSupportedValue(&not_supported);
        if (hr != com.S_OK) {
            out.* = com.VARIANT.empty();
            return hr;
        }
        out.* = com.VARIANT.fromUnknown(not_supported);
        return com.S_OK;
    }

    fn GetBoundingRectangles(
        self_base: *com.ITextRangeProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const geometry = self.geometry orelse {
            out.* = com.SafeArrayCreateVector(com.VT_R8, 0, 0);
            return if (out.* == null) com.E_OUTOFMEMORY else com.S_OK;
        };
        var screen_origin: POINT = .{ .x = 0, .y = 0 };
        if (ClientToScreen(self.parent.hwnd, &screen_origin) == 0) {
            out.* = com.SafeArrayCreateVector(com.VT_R8, 0, 0);
            return if (out.* == null) com.E_OUTOFMEMORY else com.S_OK;
        }

        const capacity = @as(usize, geometry.viewport_rows) * 4;
        const values = self.alloc.alloc(f64, capacity) catch return com.E_OUTOFMEMORY;
        defer self.alloc.free(values);
        const value_count = terminalGridRectangleValues(
            self.text,
            self.range,
            geometry,
            screen_origin,
            values,
        );
        const array = com.SafeArrayCreateVector(com.VT_R8, 0, @intCast(value_count)) orelse return com.E_OUTOFMEMORY;
        for (values[0..value_count], 0..) |value, index| {
            var array_index: i32 = @intCast(index);
            var copy = value;
            if (com.SafeArrayPutElement(array, &array_index, &copy) != com.S_OK) {
                _ = com.SafeArrayDestroy(array);
                return com.E_OUTOFMEMORY;
            }
        }
        out.* = array;
        return com.S_OK;
    }

    fn GetEnclosingElement(
        self_base: *com.ITextRangeProvider,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = &self.parent.base;
        _ = TerminalProvider.AddRef(&self.parent.base);
        return com.S_OK;
    }

    fn GetText(
        self_base: *com.ITextRangeProvider,
        max_length: i32,
        out: *?[*:0]u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = allocBstrFromUtf8Max(
            self.alloc,
            self.text[self.range.start..self.range.end],
            max_length,
        ) orelse return com.E_OUTOFMEMORY;
        return com.S_OK;
    }

    fn Move(
        self_base: *com.ITextRangeProvider,
        unit: i32,
        count: i32,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = 0;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const effective_unit = supportedTextUnit(unit) orelse return com.E_INVALIDARG;
        if (count == 0) return com.S_OK;

        if (self.range.start == self.range.end) {
            const moved = moveOffsetByUnit(self.text, effective_unit, self.range.start, count);
            self.range = .{ .start = moved.offset, .end = moved.offset };
            out.* = moved.count;
            return com.S_OK;
        }

        var candidate = textUnitRange(self.text, effective_unit, self.range.start);
        var moved_count: i32 = 0;
        const step: i32 = if (count > 0) 1 else -1;
        while (moved_count != count) {
            const moved = moveOffsetByUnit(self.text, effective_unit, candidate.start, step);
            if (moved.count == 0) break;
            const next = textUnitRange(self.text, effective_unit, moved.offset);
            if (next.start == candidate.start and next.end == candidate.end) break;
            candidate = next;
            moved_count += step;
        }
        if (moved_count != 0) self.range = candidate;
        out.* = moved_count;
        return com.S_OK;
    }

    fn MoveEndpointByUnit(
        self_base: *com.ITextRangeProvider,
        endpoint: i32,
        unit: i32,
        count: i32,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = 0;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!validEndpoint(endpoint)) return com.E_INVALIDARG;
        const effective_unit = supportedTextUnit(unit) orelse return com.E_INVALIDARG;
        const current = if (endpoint == com.TextPatternRangeEndpoint_Start) self.range.start else self.range.end;
        const moved = moveOffsetByUnit(self.text, effective_unit, current, count);

        if (endpoint == com.TextPatternRangeEndpoint_Start) {
            self.range.start = moved.offset;
            if (self.range.start > self.range.end) self.range.end = self.range.start;
        } else {
            self.range.end = moved.offset;
            if (self.range.end < self.range.start) self.range.start = self.range.end;
        }
        out.* = moved.count;
        return com.S_OK;
    }

    fn MoveEndpointByRange(
        self_base: *com.ITextRangeProvider,
        endpoint: i32,
        other: ?*com.ITextRangeProvider,
        target_endpoint: i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!validEndpoint(endpoint) or !validEndpoint(target_endpoint)) return com.E_INVALIDARG;
        const other_range = other orelse return com.E_POINTER;
        if (other_range.vtbl != &vtbl) return com.E_INVALIDARG;
        const rhs = fromBase(other_range);
        if (self.parent != rhs.parent) return com.E_INVALIDARG;

        const rhs_target = if (target_endpoint == com.TextPatternRangeEndpoint_Start) rhs.range.start else rhs.range.end;
        const target = utf8BoundaryAtOrBefore(self.text, @min(rhs_target, self.text.len));
        if (endpoint == com.TextPatternRangeEndpoint_Start) {
            self.range.start = target;
            if (self.range.start > self.range.end) self.range.end = self.range.start;
        } else {
            self.range.end = target;
            if (self.range.end < self.range.start) self.range.start = self.range.end;
        }
        return com.S_OK;
    }

    fn Select(self_base: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        if (fromBase(self_base).parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.E_NOTIMPL;
    }

    fn AddToSelection(self_base: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        if (fromBase(self_base).parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.E_NOTIMPL;
    }

    fn RemoveFromSelection(self_base: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        if (fromBase(self_base).parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.E_NOTIMPL;
    }

    fn ScrollIntoView(
        self_base: *com.ITextRangeProvider,
        _: com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        if (fromBase(self_base).parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.E_NOTIMPL;
    }

    fn GetChildren(
        self_base: *com.ITextRangeProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        if (fromBase(self_base).parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, 0);
        return if (out.* == null) com.E_OUTOFMEMORY else com.S_OK;
    }
};

/// Handle `WM_GETOBJECT` for the palette list HWND. `state` gives the
/// provider a way to query live name text from the owning Host.
/// Returns the `LRESULT` the window proc should return, or null when
/// the caller should fall through to `DefWindowProcW`.
pub fn handlePaletteListGetObject(
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    state: PaletteListState,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;

    const provider = PaletteListProvider.create(alloc, hwnd, state) catch |err| {
        std.log.warn("uia: PaletteListProvider.create failed err={}", .{err});
        return null;
    };
    defer _ = PaletteListProvider.Release(&provider.base);

    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

/// Return an already-owned palette provider for `WM_GETOBJECT`. A stable
/// provider identity is required when the widget also raises events between
/// accessibility queries.
pub fn returnPaletteListProvider(
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    provider: *PaletteListProvider,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;
    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

pub fn handleTerminalGetObject(
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    state: TerminalState,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;

    const provider = TerminalProvider.create(alloc, hwnd, state) catch |err| {
        std.log.warn("uia: TerminalProvider.create failed err={}", .{err});
        return null;
    };
    defer _ = TerminalProvider.Release(&provider.base);

    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

/// Return an already-owned terminal provider for `WM_GETOBJECT`. A stable
/// provider identity lets focus and name-change events refer to the same COM
/// object clients discover through the child HWND.
pub fn returnTerminalProvider(
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    provider: *TerminalProvider,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;
    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

fn iidEqual(a: *const com.GUID, b: *const com.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// Allocate a BSTR copy of a UTF-8 slice. The caller (UIA host)
/// frees the returned BSTR via `VariantClear → SysFreeString`, per
/// the same rule documented on `RootProvider`. Allocate the UTF-16
/// bridge buffer dynamically so terminal Value responses are not
/// truncated to a widget-title-sized stack buffer.
fn allocBstrFromUtf8(alloc: std.mem.Allocator, text: []const u8) ?[*:0]u16 {
    if (text.len == 0) {
        const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
        return com.SysAllocString(empty);
    }
    const utf16_len = std.unicode.calcUtf16LeLen(text) catch return null;
    const buf = alloc.allocSentinel(u16, utf16_len, 0) catch return null;
    defer alloc.free(buf);
    const written = std.unicode.utf8ToUtf16Le(buf, text) catch return null;
    std.debug.assert(written == utf16_len);
    return com.SysAllocString(@ptrCast(buf.ptr));
}

fn allocBstrFromUtf8Max(
    alloc: std.mem.Allocator,
    text: []const u8,
    max_utf16_len: i32,
) ?[*:0]u16 {
    if (max_utf16_len < 0) return allocBstrFromUtf8(alloc, text);
    const limited = utf8PrefixForUtf16Limit(text, @intCast(max_utf16_len)) catch return null;
    return allocBstrFromUtf8(alloc, limited);
}

fn utf8PrefixForUtf16Limit(text: []const u8, max_utf16_len: usize) ![]const u8 {
    var byte_index: usize = 0;
    var utf16_len: usize = 0;
    while (byte_index < text.len) {
        const seq_len = try std.unicode.utf8ByteSequenceLength(text[byte_index]);
        if (byte_index + seq_len > text.len) return error.TruncatedUtf8;
        const codepoint = try std.unicode.utf8Decode(text[byte_index .. byte_index + seq_len]);
        const next_utf16_len = utf16_len + if (codepoint <= 0xFFFF) @as(usize, 1) else 2;
        if (next_utf16_len > max_utf16_len) break;
        byte_index += seq_len;
        utf16_len = next_utf16_len;
    }
    return text[0..byte_index];
}

fn byteOffsetForClientPoint(text: []const u8, client_rect: RECT, point: POINT) usize {
    if (text.len == 0) return 0;

    const line_count = countTextLines(text);
    const width: usize = @intCast(@max(1, client_rect.right - client_rect.left));
    const height: usize = @intCast(@max(1, client_rect.bottom - client_rect.top));
    const x: usize = @intCast(std.math.clamp(point.x - client_rect.left, 0, client_rect.right - client_rect.left));
    const y: usize = @intCast(std.math.clamp(point.y - client_rect.top, 0, client_rect.bottom - client_rect.top));

    const line_index = @min(line_count - 1, @divTrunc(y * line_count, height));
    const line_range = lineByteRange(text, line_index);
    const line_len = line_range.end - line_range.start;
    if (line_len == 0) return line_range.start;

    const raw_offset = line_range.start + @min(line_len, @divTrunc(x * (line_len + 1), width));
    return utf8BoundaryAtOrBefore(text, raw_offset);
}

fn byteOffsetForTerminalGridPoint(
    text: []const u8,
    visible_range: terminal_text.OffsetRange,
    geometry: TerminalRangeGeometry,
    point: POINT,
) usize {
    const visible = TerminalTextRangeProvider.normalizeRange(visible_range, text.len);
    if (visible.start == visible.end or
        geometry.cell_for_byte.len != text.len or
        geometry.viewport_rows == 0 or
        geometry.cell_width <= 0 or
        geometry.cell_height <= 0)
    {
        return visible.start;
    }

    const raw_row: i64 = if (@as(f64, @floatFromInt(point.y)) <= geometry.origin_y)
        0
    else
        @intFromFloat(@floor((@as(f64, @floatFromInt(point.y)) - geometry.origin_y) / geometry.cell_height));
    const raw_column: i64 = if (@as(f64, @floatFromInt(point.x)) <= geometry.origin_x)
        0
    else
        @intFromFloat(@floor((@as(f64, @floatFromInt(point.x)) - geometry.origin_x) / geometry.cell_width));
    const target_row: i32 = @intCast(std.math.clamp(
        raw_row,
        0,
        @as(i64, @intCast(geometry.viewport_rows - 1)),
    ));
    const target_column: u32 = @intCast(std.math.clamp(
        raw_column,
        0,
        @as(i64, @intCast(@max(1, geometry.viewport_columns) - 1)),
    ));

    var saw_target_row = false;
    var row_end = visible.start;
    var index = visible.start;
    while (index < visible.end) {
        if (index > 0 and (text[index] & 0b1100_0000) == 0b1000_0000) {
            index += 1;
            continue;
        }
        const cell = geometry.cell_for_byte[index];
        if (cell.row > target_row and saw_target_row) break;
        if (cell.row != target_row) {
            index += std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            continue;
        }

        saw_target_row = true;
        if (cell.width == 0) {
            row_end = index;
            break;
        }
        if (target_column < cell.column + cell.width) return index;

        const scalar_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        row_end = @min(visible.end, index + scalar_len);
        index += scalar_len;
    }

    return if (saw_target_row) row_end else if (target_row == 0) visible.start else visible.end;
}

fn countTextLines(text: []const u8) usize {
    var count: usize = 1;
    for (text, 0..) |c, i| {
        if (c == '\n' and i + 1 < text.len) count += 1;
    }
    return count;
}

fn terminalGridRectangleValues(
    text: []const u8,
    range: terminal_text.OffsetRange,
    geometry: TerminalRangeGeometry,
    screen_origin: POINT,
    values: []f64,
) usize {
    const normalized = TerminalTextRangeProvider.normalizeRange(range, text.len);
    if (normalized.start == normalized.end or
        geometry.cell_for_byte.len != text.len or
        geometry.cell_width <= 0 or geometry.cell_height <= 0)
    {
        return 0;
    }

    var written: usize = 0;
    var active_row: ?i32 = null;
    var min_column: u32 = 0;
    var max_column: u32 = 0;
    for (geometry.cell_for_byte[normalized.start..normalized.end]) |cell| {
        if (cell.width == 0 or cell.row < 0 or cell.row >= @as(i32, @intCast(geometry.viewport_rows))) continue;
        if (active_row == null or active_row.? != cell.row) {
            if (active_row) |row| {
                if (written + 4 > values.len) break;
                writeGridRectangle(values[written..][0..4], screen_origin, geometry, row, min_column, max_column);
                written += 4;
            }
            active_row = cell.row;
            min_column = cell.column;
            max_column = cell.column + cell.width;
        } else {
            min_column = @min(min_column, cell.column);
            max_column = @max(max_column, cell.column + cell.width);
        }
    }
    if (active_row) |row| {
        if (written + 4 <= values.len) {
            writeGridRectangle(values[written..][0..4], screen_origin, geometry, row, min_column, max_column);
            written += 4;
        }
    }
    return written;
}

fn writeGridRectangle(
    values: []f64,
    screen_origin: POINT,
    geometry: TerminalRangeGeometry,
    row: i32,
    min_column: u32,
    max_column: u32,
) void {
    values[0] = @as(f64, @floatFromInt(screen_origin.x)) + geometry.origin_x +
        @as(f64, @floatFromInt(min_column)) * geometry.cell_width;
    values[1] = @as(f64, @floatFromInt(screen_origin.y)) + geometry.origin_y +
        @as(f64, @floatFromInt(row)) * geometry.cell_height;
    values[2] = @as(f64, @floatFromInt(max_column - min_column)) * geometry.cell_width;
    values[3] = geometry.cell_height;
}

fn lineByteRange(text: []const u8, target_line: usize) terminal_text.OffsetRange {
    var line_index: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c != '\n' or i + 1 == text.len) continue;
        if (line_index == target_line) return .{ .start = start, .end = i };
        line_index += 1;
        start = i + 1;
    }

    var end = text.len;
    if (end > start and text[end - 1] == '\n') end -= 1;
    return .{ .start = start, .end = end };
}

fn lineByteRangeForOffset(text: []const u8, offset: usize) terminal_text.OffsetRange {
    const safe_offset = @min(offset, text.len);
    var start = safe_offset;
    while (start > 0 and text[start - 1] != '\n') : (start -= 1) {}

    var end = safe_offset;
    while (end < text.len and text[end] != '\n') : (end += 1) {}

    return .{
        .start = utf8BoundaryAtOrBefore(text, start),
        .end = utf8BoundaryAtOrBefore(text, end),
    };
}

fn characterByteRange(text: []const u8, offset: usize) terminal_text.OffsetRange {
    if (text.len == 0) return .{ .start = 0, .end = 0 };

    const start = utf8BoundaryAtOrBefore(text, @min(offset, text.len - 1));
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
    return .{ .start = start, .end = @min(text.len, start + len) };
}

fn wordByteRange(text: []const u8, offset: usize) terminal_text.OffsetRange {
    if (text.len == 0) return .{ .start = 0, .end = 0 };

    var start = utf8BoundaryAtOrBefore(text, @min(offset, text.len - 1));
    while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) : (start -= 1) {}

    var end = @min(offset, text.len);
    while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}

    return .{
        .start = utf8BoundaryAtOrBefore(text, start),
        .end = utf8BoundaryAtOrBefore(text, end),
    };
}

fn utf8BoundaryAtOrBefore(text: []const u8, offset: usize) usize {
    var index = @min(offset, text.len);
    while (index > 0 and index < text.len and (text[index] & 0b1100_0000) == 0b1000_0000) : (index -= 1) {}
    return index;
}

fn validEndpoint(endpoint: i32) bool {
    return endpoint == com.TextPatternRangeEndpoint_Start or
        endpoint == com.TextPatternRangeEndpoint_End;
}

fn supportedTextUnit(unit: i32) ?i32 {
    return switch (unit) {
        com.TextUnit_Character => com.TextUnit_Character,
        com.TextUnit_Format, com.TextUnit_Word => com.TextUnit_Word,
        com.TextUnit_Line => com.TextUnit_Line,
        com.TextUnit_Paragraph, com.TextUnit_Page, com.TextUnit_Document => com.TextUnit_Document,
        else => null,
    };
}

fn textUnitRange(text: []const u8, unit: i32, offset: usize) terminal_text.OffsetRange {
    return switch (unit) {
        com.TextUnit_Character => characterByteRange(text, offset),
        com.TextUnit_Word => wordByteRange(text, offset),
        com.TextUnit_Line => lineByteRangeForOffset(text, offset),
        com.TextUnit_Document => .{ .start = 0, .end = text.len },
        else => unreachable,
    };
}

fn findTextIndex(haystack: []const u8, needle: []const u8, backward: bool) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    return if (backward)
        std.mem.lastIndexOf(u8, haystack, needle)
    else
        std.mem.indexOf(u8, haystack, needle);
}

fn findTextRangeIgnoreCase(
    alloc: std.mem.Allocator,
    haystack: []const u8,
    needle_utf16: []const u16,
    backward: bool,
) !?terminal_text.OffsetRange {
    if (needle_utf16.len == 0 or haystack.len == 0) return null;
    if (needle_utf16.len > std.math.maxInt(i32)) return null;

    const haystack_utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, haystack);
    defer alloc.free(haystack_utf16);
    if (needle_utf16.len > haystack_utf16.len) return null;

    const no_boundary = std.math.maxInt(usize);
    const byte_for_utf16_offset = try alloc.alloc(usize, haystack_utf16.len + 1);
    defer alloc.free(byte_for_utf16_offset);
    @memset(byte_for_utf16_offset, no_boundary);

    var byte_offset: usize = 0;
    var utf16_offset: usize = 0;
    byte_for_utf16_offset[0] = 0;
    while (byte_offset < haystack.len) {
        const scalar_len = try std.unicode.utf8ByteSequenceLength(haystack[byte_offset]);
        if (byte_offset + scalar_len > haystack.len) return error.TruncatedUtf8;
        const codepoint = try std.unicode.utf8Decode(haystack[byte_offset .. byte_offset + scalar_len]);
        byte_offset += scalar_len;
        utf16_offset += if (codepoint <= 0xFFFF) 1 else 2;
        byte_for_utf16_offset[utf16_offset] = byte_offset;
    }

    var match: ?terminal_text.OffsetRange = null;
    const last_start = haystack_utf16.len - needle_utf16.len;
    for (0..last_start + 1) |start| {
        const end = start + needle_utf16.len;
        if (byte_for_utf16_offset[start] == no_boundary or
            byte_for_utf16_offset[end] == no_boundary) continue;
        if (CompareStringOrdinal(
            haystack_utf16.ptr + start,
            @intCast(needle_utf16.len),
            needle_utf16.ptr,
            @intCast(needle_utf16.len),
            1,
        ) != 2) continue;

        match = .{
            .start = byte_for_utf16_offset[start],
            .end = byte_for_utf16_offset[end],
        };
        if (!backward) break;
    }
    return match;
}

const OffsetMove = struct {
    offset: usize,
    count: i32,
};

fn moveOffsetByUnit(text: []const u8, unit: i32, offset: usize, count: i32) OffsetMove {
    var result = utf8BoundaryAtOrBefore(text, offset);
    var moved: i32 = 0;
    if (count > 0) {
        while (moved < count) {
            const next = nextUnitOffset(text, unit, result);
            if (next == result) break;
            result = next;
            moved += 1;
        }
    } else {
        while (moved > count) {
            const previous = previousUnitOffset(text, unit, result);
            if (previous == result) break;
            result = previous;
            moved -= 1;
        }
    }
    return .{ .offset = result, .count = moved };
}

fn nextUnitOffset(text: []const u8, unit: i32, offset: usize) usize {
    const current = utf8BoundaryAtOrBefore(text, offset);
    if (current >= text.len) return text.len;
    return switch (unit) {
        com.TextUnit_Character => blk: {
            const len = std.unicode.utf8ByteSequenceLength(text[current]) catch 1;
            break :blk @min(text.len, current + len);
        },
        com.TextUnit_Word => blk: {
            var i = current;
            while (i < text.len and !std.ascii.isWhitespace(text[i])) : (i += 1) {}
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            break :blk utf8BoundaryAtOrBefore(text, i);
        },
        com.TextUnit_Line => blk: {
            const newline = std.mem.indexOfScalarPos(u8, text, current, '\n') orelse break :blk text.len;
            break :blk @min(text.len, newline + 1);
        },
        com.TextUnit_Document => text.len,
        else => current,
    };
}

fn previousUnitOffset(text: []const u8, unit: i32, offset: usize) usize {
    const current = utf8BoundaryAtOrBefore(text, offset);
    if (current == 0) return 0;
    return switch (unit) {
        com.TextUnit_Character => utf8BoundaryAtOrBefore(text, current - 1),
        com.TextUnit_Word => blk: {
            var i = current;
            while (i > 0 and std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}
            while (i > 0 and !std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}
            break :blk utf8BoundaryAtOrBefore(text, i);
        },
        com.TextUnit_Line => blk: {
            var probe = current;
            if (probe > 0 and text[probe - 1] == '\n') probe -= 1;
            while (probe > 0 and text[probe - 1] != '\n') : (probe -= 1) {}
            if (probe < current) break :blk probe;
            if (probe == 0) break :blk 0;
            probe -= 1;
            while (probe > 0 and text[probe - 1] != '\n') : (probe -= 1) {}
            break :blk probe;
        },
        com.TextUnit_Document => 0,
        else => current,
    };
}

fn visibleOffsetToDocumentOffset(
    document_text: []const u8,
    visible_range: terminal_text.OffsetRange,
    visible_offset: usize,
) usize {
    if (document_text.len == 0) return 0;

    const visible_len = visible_range.end - visible_range.start;
    const raw_offset = @min(document_text.len, visible_range.start + @min(visible_offset, visible_len));
    return utf8BoundaryAtOrBefore(document_text, raw_offset);
}

fn safeI32FromUiaCoord(coord: f64) ?i32 {
    if (!std.math.isFinite(coord)) return null;
    const min_i32_float: f64 = @floatFromInt(std.math.minInt(i32));
    const max_i32_float: f64 = @floatFromInt(std.math.maxInt(i32));
    return @intFromFloat(std.math.clamp(coord, min_i32_float, max_i32_float));
}

test "PaletteListProvider refcount balances" {
    var counter: u32 = 0;
    const name_fn = struct {
        fn name(ctx: *anyopaque, buf: []u8) []const u8 {
            const c: *u32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
            return std.fmt.bufPrint(buf, "call {d}", .{c.*}) catch "";
        }
    }.name;
    const state: PaletteListState = .{
        .ctx = @ptrCast(&counter),
        .name = &name_fn,
    };

    var p = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    try std.testing.expectEqual(@as(u32, 2), PaletteListProvider.AddRef(&p.base));
    try std.testing.expectEqual(@as(u32, 1), PaletteListProvider.Release(&p.base));
    try std.testing.expectEqual(@as(u32, 0), PaletteListProvider.Release(&p.base));
}

test "PaletteListProvider QueryInterface accepts IUnknown" {
    var counter: u32 = 0;
    const name_fn = struct {
        fn name(ctx: *anyopaque, buf: []u8) []const u8 {
            _ = ctx;
            return std.fmt.bufPrint(buf, "test", .{}) catch "";
        }
    }.name;
    const state: PaletteListState = .{ .ctx = @ptrCast(&counter), .name = &name_fn };

    var p = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = PaletteListProvider.Release(&p.base);

    var out: ?*anyopaque = null;
    const hr = PaletteListProvider.QueryInterface(&p.base, &com.IID_IUnknown, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    _ = PaletteListProvider.Release(&p.base); // Drop the QI ref.
}

const TestPaletteState = struct {
    count: usize = 3,
    selected: ?usize = 1,
    id_base: u64 = 100,
    selected_by_provider: ?usize = null,
    reentrant_provider: ?*PaletteListProvider = null,
    reentrant_queries: u32 = 0,
    list_geometry: ?PaletteListGeometry = null,
    disabled_index: ?usize = null,

    fn name(_: *anyopaque, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "palette", .{}) catch "";
    }

    fn rowCount(ctx: *anyopaque) usize {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        return self.count;
    }

    fn selectedIndex(ctx: *anyopaque) ?usize {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        return self.selected;
    }

    fn rowName(_: *anyopaque, index: usize, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "row {d}", .{index}) catch "";
    }

    fn rowId(ctx: *anyopaque, index: usize) u64 {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        return self.id_base + index;
    }

    fn rowEnabled(ctx: *anyopaque, index: usize) bool {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        return self.disabled_index != index;
    }

    fn selectRow(ctx: *anyopaque, index: usize) void {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        self.selected_by_provider = index;
        if (self.reentrant_provider) |provider| {
            var value = com.VARIANT.empty();
            if (PaletteListProvider.GetPropertyValue(
                &provider.base,
                constants.UIA_ControlTypePropertyId,
                &value,
            ) == com.S_OK) self.reentrant_queries += 1;
        }
    }

    fn geometry(ctx: *anyopaque) ?PaletteListGeometry {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        return self.list_geometry;
    }

    fn state(self: *TestPaletteState) PaletteListState {
        return .{
            .ctx = self,
            .name = name,
            .row_count = rowCount,
            .selected_index = selectedIndex,
            .row_name = rowName,
            .row_enabled = rowEnabled,
            .row_id = rowId,
            .select_row = selectRow,
            .geometry = geometry,
        };
    }
};

test "Palette geometry maps scrolled rows and hit testing" {
    var state_data = TestPaletteState{
        .count = 10,
        .selected = 5,
        .list_geometry = .{
            .bounds = .{ .left = 100, .top = 200, .width = 300, .height = 108 },
            .first_visible = 4,
            .visible_count = 3,
            .row_height = 36,
        },
    };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);

    const visible = provider.rowBounds(5).?;
    try std.testing.expectEqual(@as(f64, 100), visible.left);
    try std.testing.expectEqual(@as(f64, 236), visible.top);
    try std.testing.expectEqual(@as(f64, 300), visible.width);
    try std.testing.expectEqual(@as(f64, 36), visible.height);
    try std.testing.expect(provider.rowBounds(3) == null);
    try std.testing.expect(provider.rowBounds(7) == null);

    var hit: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.FragmentRootElementProviderFromPoint(
        &provider.fragment_root,
        150,
        218,
        &hit,
    ));
    defer if (hit) |row| {
        _ = PaletteRowProvider.FragmentRelease(row);
    };
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(usize, 4), PaletteRowProvider.fromFragment(hit.?).index);

    var outside: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.FragmentRootElementProviderFromPoint(
        &provider.fragment_root,
        400,
        218,
        &outside,
    ));
    try std.testing.expectEqual(@as(?*com.IRawElementProviderFragment, null), outside);
}

test "PaletteListProvider exposes one-selection container semantics without fabricated focus" {
    var state_data = TestPaletteState{ .count = 3, .selected = 1 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);

    var pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        PaletteListProvider.GetPatternProvider(&provider.base, constants.UIA_SelectionPatternId, &pattern),
    );
    try std.testing.expect(pattern != null);
    defer _ = PaletteListProvider.SelectionRelease(@ptrCast(@alignCast(pattern.?)));

    var selected: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.SelectionGetSelection(&provider.selection_iface, &selected));
    try std.testing.expect(selected != null);
    try std.testing.expectEqual(com.S_OK, com.SafeArrayDestroy(selected));

    var multiple: com.BOOL = 1;
    var required: com.BOOL = 0;
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.SelectionGetCanSelectMultiple(&provider.selection_iface, &multiple));
    try std.testing.expectEqual(@as(com.BOOL, 0), multiple);
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.SelectionGetIsSelectionRequired(&provider.selection_iface, &required));
    try std.testing.expectEqual(@as(com.BOOL, 1), required);

    var focus: ?*com.IRawElementProviderFragment = @ptrFromInt(0x10);
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.FragmentRootGetFocus(&provider.fragment_root, &focus));
    try std.testing.expect(focus == null);

    provider.detach();
    required = 1;
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteListProvider.SelectionGetIsSelectionRequired(&provider.selection_iface, &required),
    );
    try std.testing.expectEqual(@as(com.BOOL, 0), required);
}

test "Palette row selection rejects disabled items" {
    var state_data = TestPaletteState{ .count = 2, .selected = 0, .disabled_index = 1 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);
    const row = provider.createRow(1).?;
    defer _ = PaletteRowProvider.Release(&row.base);

    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTENABLED, PaletteRowProvider.Select(&row.selection_item));
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTENABLED, PaletteRowProvider.AddToSelection(&row.selection_item));
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTENABLED, PaletteRowProvider.RemoveFromSelection(&row.selection_item));
    try std.testing.expectEqual(@as(?usize, null), state_data.selected_by_provider);
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTENABLED, PaletteRowProvider.SetFocus(&row.fragment));
}

test "Palette row enforces required single-selection operations" {
    var state_data = TestPaletteState{ .count = 2, .selected = 0 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);
    const selected_row = provider.createRow(0).?;
    defer _ = PaletteRowProvider.Release(&selected_row.base);
    const unselected_row = provider.createRow(1).?;
    defer _ = PaletteRowProvider.Release(&unselected_row.base);

    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.AddToSelection(&selected_row.selection_item));
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        PaletteRowProvider.RemoveFromSelection(&selected_row.selection_item),
    );
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        PaletteRowProvider.AddToSelection(&unselected_row.selection_item),
    );
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.RemoveFromSelection(&unselected_row.selection_item));
    try std.testing.expectEqual(@as(?usize, null), state_data.selected_by_provider);
}

test "PaletteListProvider fragment navigation reaches rows and parent" {
    var state_data = TestPaletteState{};
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);

    var first: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(
        com.S_OK,
        PaletteListProvider.FragmentNavigate(
            &provider.fragment,
            com.NavigateDirection_FirstChild,
            &first,
        ),
    );
    defer _ = PaletteRowProvider.FragmentRelease(first.?);
    try std.testing.expectEqual(@as(usize, 0), PaletteRowProvider.fromFragment(first.?).index);

    var next: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.Navigate(first.?, com.NavigateDirection_NextSibling, &next));
    defer _ = PaletteRowProvider.FragmentRelease(next.?);
    try std.testing.expectEqual(@as(usize, 1), PaletteRowProvider.fromFragment(next.?).index);

    var parent: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.Navigate(next.?, com.NavigateDirection_Parent, &parent));
    try std.testing.expect(parent != null);
    try std.testing.expectEqual(@as(u32, 3), PaletteListProvider.FragmentRelease(parent.?));
}

test "Palette row retains its parent and balances QueryInterface refs" {
    var state_data = TestPaletteState{ .count = 1 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    const row = provider.createRow(0).?;
    try std.testing.expectEqual(@as(u32, 1), PaletteListProvider.Release(&provider.base));

    var selection: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.QueryInterface(&row.base, &com.IID_ISelectionItemProvider, &selection));
    try std.testing.expectEqual(@as(u32, 1), PaletteRowProvider.SelectionRelease(@ptrCast(@alignCast(selection.?))));
    try std.testing.expectEqual(@as(u32, 0), PaletteRowProvider.Release(&row.base));
}

test "Palette row late query reports unavailable after removal and detach" {
    var state_data = TestPaletteState{ .count = 1 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);
    const row = provider.createRow(0).?;
    defer _ = PaletteRowProvider.Release(&row.base);

    state_data.count = 0;
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetPropertyValue(&row.base, constants.UIA_NamePropertyId, &value),
    );
    var pattern: ?*com.IUnknown = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetPatternProvider(&row.base, constants.UIA_SelectionItemPatternId, &pattern),
    );
    try std.testing.expect(pattern == null);
    var root: ?*com.IRawElementProviderFragmentRoot = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetFragmentRoot(&row.fragment, &root),
    );
    try std.testing.expect(root == null);
    var container: ?*com.IRawElementProviderSimple = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetSelectionContainer(&row.selection_item, &container),
    );
    try std.testing.expect(container == null);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.AddToSelection(&row.selection_item),
    );
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.RemoveFromSelection(&row.selection_item),
    );

    state_data.count = 1;
    provider.detach();
    var selected: com.BOOL = 0;
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetIsSelected(&row.selection_item, &selected),
    );
}

test "Palette row late query rejects a different item at the same filtered index" {
    var state_data = TestPaletteState{ .count = 1, .id_base = 100 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);
    const row = provider.createRow(0).?;
    defer _ = PaletteRowProvider.Release(&row.base);

    state_data.id_base = 200;
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetPropertyValue(&row.base, constants.UIA_NamePropertyId, &value),
    );
}

test "Palette row selection callback may reenter provider" {
    var state_data = TestPaletteState{ .count = 2 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);
    state_data.reentrant_provider = provider;
    const row = provider.createRow(1).?;
    defer _ = PaletteRowProvider.Release(&row.base);

    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.Select(&row.selection_item));
    try std.testing.expectEqual(@as(?usize, 1), state_data.selected_by_provider);
    try std.testing.expectEqual(@as(u32, 1), state_data.reentrant_queries);
}

test "TerminalProvider does not expose multiline terminal text through ValuePattern" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?*anyopaque = null;
    const hr = TerminalProvider.QueryInterface(&p.base, &com.IID_IValueProvider, &out);
    try std.testing.expectEqual(com.E_NOINTERFACE, hr);
    try std.testing.expect(out == null);

    var pattern: ?*com.IUnknown = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&p.base, constants.UIA_ValuePatternId, &pattern),
    );
    try std.testing.expect(pattern == null);
}

test "TerminalProvider QueryInterface accepts TextProvider and TextProvider2" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?*anyopaque = null;
    const hr = TerminalProvider.QueryInterface(&p.base, &com.IID_ITextProvider, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    _ = TerminalProvider.TextRelease(@ptrCast(@alignCast(out.?)));

    out = null;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.QueryInterface(&p.base, &com.IID_ITextProvider2, &out));
    try std.testing.expect(out != null);
    _ = TerminalProvider.Text2Release(@ptrCast(@alignCast(out.?)));
}

test "TerminalProvider exposes Text pattern provider" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?*com.IUnknown = null;
    const hr = TerminalProvider.GetPatternProvider(&p.base, constants.UIA_TextPatternId, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    _ = TerminalProvider.TextRelease(@ptrCast(@alignCast(out.?)));

    out = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&p.base, constants.UIA_TextPattern2Id, &out),
    );
    try std.testing.expect(out != null);
    _ = TerminalProvider.Text2Release(@ptrCast(@alignCast(out.?)));
}

test "TerminalProvider TextProvider2 exposes active degenerate caret range" {
    var state_data = TestTerminalStateData{ .caret_offset = 6 };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var active: com.BOOL = 0;
    var caret: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetCaretRange(&provider.text2_iface, &active, &caret),
    );
    defer _ = TerminalTextRangeProvider.Release(caret.?);
    try std.testing.expectEqual(@as(com.BOOL, 1), active);
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 6, .end = 6 },
        TerminalTextRangeProvider.fromBase(caret.?).range,
    );

    var annotation: ?*com.ITextRangeProvider = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.E_NOTIMPL,
        TerminalProvider.RangeFromAnnotation(&provider.text2_iface, null, &annotation),
    );
    try std.testing.expect(annotation == null);
}

test "TerminalProvider refcount and state retain balance across text provider refs" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    try std.testing.expectEqual(@as(u32, 1), state_data.retains);
    try std.testing.expectEqual(@as(u32, 0), state_data.releases);

    var out: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&p.base, constants.UIA_TextPatternId, &out),
    );
    try std.testing.expect(out != null);
    try std.testing.expectEqual(@as(u32, 3), TerminalProvider.AddRef(&p.base));
    try std.testing.expectEqual(@as(u32, 2), TerminalProvider.Release(&p.base));
    try std.testing.expectEqual(@as(u32, 1), TerminalProvider.TextRelease(@ptrCast(@alignCast(out.?))));
    try std.testing.expectEqual(@as(u32, 0), TerminalProvider.Release(&p.base));
    try std.testing.expectEqual(@as(u32, 1), state_data.retains);
    try std.testing.expectEqual(@as(u32, 1), state_data.releases);
}

test "TerminalProvider reports no legacy selection for a PTY-owned caret" {
    var state_data = TestTerminalStateData{ .caret_offset = 6 };
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var selection: i32 = -1;
    const hr = TerminalProvider.get_SupportedTextSelection(&p.text_iface, &selection);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(com.SupportedTextSelection_None, selection);

    var ranges: ?*com.SAFEARRAY = @ptrFromInt(0x10);
    try std.testing.expectEqual(com.S_OK, TerminalProvider.GetSelection(&p.text_iface, &ranges));
    try std.testing.expect(ranges == null);
}

test "TerminalProvider visible ranges returns a SAFEARRAY" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var ranges: ?*com.SAFEARRAY = null;
    const hr = TerminalProvider.GetVisibleRanges(&p.text_iface, &ranges);
    defer _ = com.SafeArrayDestroy(ranges);

    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(ranges != null);
    try std.testing.expectEqual(@as(u32, 1), state_data.value_calls);
    try std.testing.expectEqual(@as(u32, 1), state_data.visible_value_calls);
}

test "TerminalProvider reports document control type" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var value = com.VARIANT.empty();
    const hr = TerminalProvider.GetPropertyValue(&p.base, constants.UIA_ControlTypePropertyId, &value);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(constants.UIA_DocumentControlTypeId, value.value.i4);
}

test "TerminalProvider DocumentRange returns terminal text" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var range: ?*com.ITextRangeProvider = null;
    const range_hr = TerminalProvider.get_DocumentRange(&p.text_iface, &range);
    try std.testing.expectEqual(com.S_OK, range_hr);
    defer _ = TerminalTextRangeProvider.Release(range.?);

    var out: ?[*:0]u16 = null;
    const text_hr = TerminalTextRangeProvider.GetText(range.?, -1, &out);
    defer com.SysFreeString(out);

    try std.testing.expectEqual(com.S_OK, text_hr);
    try std.testing.expect(out != null);
    try std.testing.expectEqual(@as(u32, 11), com.SysStringLen(out));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("hello\nworld"), out.?[0..11]);
    try std.testing.expectEqual(@as(u32, 1), state_data.value_calls);
}

test "TerminalTextRangeProvider GetText honors UTF-16 maxLength" {
    var state_data = TestTerminalStateData{ .value_text = "A🔥B" };
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.get_DocumentRange(&p.text_iface, &range));
    defer _ = TerminalTextRangeProvider.Release(range.?);

    var one: ?[*:0]u16 = null;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.GetText(range.?, 1, &one));
    defer com.SysFreeString(one);
    try std.testing.expectEqual(@as(u32, 1), com.SysStringLen(one));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("A"), one.?[0..1]);

    var three: ?[*:0]u16 = null;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.GetText(range.?, 3, &three));
    defer com.SysFreeString(three);
    try std.testing.expectEqual(@as(u32, 3), com.SysStringLen(three));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("A🔥"), three.?[0..3]);
}

test "TerminalTextRangeProvider clone and enclosing element retain parent" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.get_DocumentRange(&p.text_iface, &range));
    defer _ = TerminalTextRangeProvider.Release(range.?);

    var clone: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.Clone(range.?, &clone));
    defer _ = TerminalTextRangeProvider.Release(clone.?);

    const original = TerminalTextRangeProvider.fromBase(range.?);
    const cloned = TerminalTextRangeProvider.fromBase(clone.?);
    try std.testing.expectEqual(original.snapshot, cloned.snapshot);

    var same: com.BOOL = 0;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.Compare(range.?, clone, &same));
    try std.testing.expectEqual(@as(com.BOOL, 1), same);

    var enclosing: ?*com.IRawElementProviderSimple = null;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.GetEnclosingElement(clone.?, &enclosing));
    try std.testing.expect(enclosing != null);
    try std.testing.expectEqual(@as(u32, 3), TerminalProvider.Release(enclosing.?));
}

test "TerminalTextRangeProvider Clone consumes retained snapshot reference on allocation failure" {
    var state_data = TestTerminalStateData{};
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, state_data.value_text),
        .{ .start = 0, .end = state_data.value_text.len },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    const original_alloc = range.alloc;
    defer range.alloc = original_alloc;
    const references_before = range.snapshot.refcount.load(.monotonic);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    range.alloc = failing.allocator();

    var clone: ?*com.ITextRangeProvider = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.E_OUTOFMEMORY,
        TerminalTextRangeProvider.Clone(&range.base, &clone),
    );
    try std.testing.expect(clone == null);
    try std.testing.expectEqual(references_before, range.snapshot.refcount.load(.monotonic));
}

test "TerminalTextRangeProvider owned creation frees text and geometry on snapshot allocation failure" {
    var state_data = TestTerminalStateData{};
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    const text = try std.testing.allocator.dupe(u8, state_data.value_text);
    const cells = try std.testing.allocator.alloc(terminal_text.TerminalCellPosition, text.len);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        TerminalTextRangeProvider.createOwnedWithGeometry(
            failing.allocator(),
            provider,
            text,
            .{ .start = 0, .end = text.len },
            .{
                .cell_for_byte = cells,
                .viewport_rows = 24,
                .viewport_columns = 80,
                .cell_width = 8,
                .cell_height = 16,
                .origin_x = 0,
                .origin_y = 0,
            },
        ),
    );
}

test "TerminalTextRangeProvider owned creation frees snapshot text and geometry on range allocation failure" {
    var state_data = TestTerminalStateData{};
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    const text = try std.testing.allocator.dupe(u8, state_data.value_text);
    const cells = try std.testing.allocator.alloc(terminal_text.TerminalCellPosition, text.len);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(
        error.OutOfMemory,
        TerminalTextRangeProvider.createOwnedWithGeometry(
            failing.allocator(),
            provider,
            text,
            .{ .start = 0, .end = text.len },
            .{
                .cell_for_byte = cells,
                .viewport_rows = 24,
                .viewport_columns = 80,
                .cell_width = 8,
                .cell_height = 16,
                .origin_x = 0,
                .origin_y = 0,
            },
        ),
    );
}

test "TerminalTextRangeProvider owned creation releases text and geometry on success" {
    var state_data = TestTerminalStateData{};
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    const text = try std.testing.allocator.dupe(u8, state_data.value_text);
    const cells = try std.testing.allocator.alloc(terminal_text.TerminalCellPosition, text.len);
    const range = try TerminalTextRangeProvider.createOwnedWithGeometry(
        std.testing.allocator,
        provider,
        text,
        .{ .start = 0, .end = text.len },
        .{
            .cell_for_byte = cells,
            .viewport_rows = 24,
            .viewport_columns = 80,
            .cell_width = 8,
            .cell_height = 16,
            .origin_x = 0,
            .origin_y = 0,
        },
    );
    try std.testing.expectEqual(@as(u32, 0), TerminalTextRangeProvider.Release(&range.base));
}

test "TerminalTextRangeProvider CompareEndpoints rejects different parents" {
    var left_data = TestTerminalStateData{};
    var right_data = TestTerminalStateData{};

    var left = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), testTerminalState(&left_data));
    defer _ = TerminalProvider.Release(&left.base);
    var right = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x2), testTerminalState(&right_data));
    defer _ = TerminalProvider.Release(&right.base);

    var left_range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.get_DocumentRange(&left.text_iface, &left_range));
    defer _ = TerminalTextRangeProvider.Release(left_range.?);

    var right_range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.get_DocumentRange(&right.text_iface, &right_range));
    defer _ = TerminalTextRangeProvider.Release(right_range.?);

    var comparison: i32 = 0;
    try std.testing.expectEqual(
        com.E_INVALIDARG,
        TerminalTextRangeProvider.CompareEndpoints(
            left_range.?,
            com.TextPatternRangeEndpoint_Start,
            right_range,
            com.TextPatternRangeEndpoint_Start,
            &comparison,
        ),
    );
}

test "TerminalTextRangeProvider ExpandToEnclosingUnit supports basic units" {
    var state_data = TestTerminalStateData{ .value_text = "hello world\nnext" };
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    const text = try std.testing.allocator.dupe(u8, state_data.value_text);
    var range_provider = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        p,
        text,
        .{ .start = 7, .end = 7 },
    );
    defer _ = TerminalTextRangeProvider.Release(&range_provider.base);

    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.ExpandToEnclosingUnit(&range_provider.base, com.TextUnit_Word));
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 6, .end = 11 }, range_provider.range);

    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.ExpandToEnclosingUnit(&range_provider.base, com.TextUnit_Line));
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 0, .end = 11 }, range_provider.range);

    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.ExpandToEnclosingUnit(&range_provider.base, com.TextUnit_Document));
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 0, .end = state_data.value_text.len }, range_provider.range);
}

test "TerminalTextRangeProvider moves by UTF-8 character word and line" {
    var state_data = TestTerminalStateData{ .value_text = "A🔥 B\nnext" };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    const text = try std.testing.allocator.dupe(u8, state_data.value_text);
    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        text,
        .{ .start = 0, .end = 0 },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    var moved: i32 = 0;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.Move(&range.base, com.TextUnit_Character, 2, &moved),
    );
    try std.testing.expectEqual(@as(i32, 2), moved);
    try std.testing.expectEqual(@as(usize, 5), range.range.start);
    try std.testing.expectEqual(range.range.start, range.range.end);

    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.Move(&range.base, com.TextUnit_Word, 1, &moved),
    );
    try std.testing.expectEqual(@as(i32, 1), moved);
    try std.testing.expectEqual(@as(usize, 6), range.range.start);

    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.Move(&range.base, com.TextUnit_Line, 1, &moved),
    );
    try std.testing.expectEqual(@as(i32, 1), moved);
    try std.testing.expectEqual(@as(usize, 8), range.range.start);
}

test "TerminalTextRangeProvider normalizes a non-degenerate move to the requested unit" {
    var state_data = TestTerminalStateData{ .value_text = "one\ntwo\nthree" };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    const text = try std.testing.allocator.dupe(u8, state_data.value_text);
    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        text,
        .{ .start = 1, .end = 2 },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    var moved: i32 = 0;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.Move(&range.base, com.TextUnit_Line, 1, &moved),
    );
    try std.testing.expectEqual(@as(i32, 1), moved);
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 4, .end = 7 }, range.range);

    range.range = .{ .start = 8, .end = 13 };
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.Move(&range.base, com.TextUnit_Line, 1, &moved),
    );
    try std.testing.expectEqual(@as(i32, 0), moved);
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 8, .end = 13 }, range.range);

    range.range = .{ .start = 4, .end = 7 };
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.Move(&range.base, com.TextUnit_Word, 99, &moved),
    );
    try std.testing.expectEqual(@as(i32, 1), moved);
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 8, .end = 13 }, range.range);

    range.range = .{ .start = 12, .end = 13 };
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.Move(&range.base, com.TextUnit_Character, 1, &moved),
    );
    try std.testing.expectEqual(@as(i32, 0), moved);
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 12, .end = 13 }, range.range);

    range.range = .{ .start = 0, .end = state_data.value_text.len };
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.Move(&range.base, com.TextUnit_Document, 1, &moved),
    );
    try std.testing.expectEqual(@as(i32, 0), moved);
}

test "TerminalTextRangeProvider endpoint movement collapses crossing ranges" {
    var state_data = TestTerminalStateData{ .value_text = "one two" };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    const text = try std.testing.allocator.dupe(u8, state_data.value_text);
    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        text,
        .{ .start = 0, .end = 3 },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    var moved: i32 = 0;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.MoveEndpointByUnit(
            &range.base,
            com.TextPatternRangeEndpoint_Start,
            com.TextUnit_Character,
            5,
            &moved,
        ),
    );
    try std.testing.expectEqual(@as(i32, 5), moved);
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 5, .end = 5 }, range.range);

    try std.testing.expectEqual(
        com.E_INVALIDARG,
        TerminalTextRangeProvider.MoveEndpointByUnit(
            &range.base,
            99,
            com.TextUnit_Character,
            1,
            &moved,
        ),
    );
}

test "TerminalTextRangeProvider finds text backward and case-insensitively" {
    var state_data = TestTerminalStateData{ .value_text = "one TWO one two" };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, state_data.value_text),
        .{ .start = 0, .end = state_data.value_text.len },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    var match: ?*com.ITextRangeProvider = null;
    const needle = com.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral("TWO")).?;
    defer com.SysFreeString(needle);
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.FindText(&range.base, needle, 1, 1, &match),
    );
    defer _ = TerminalTextRangeProvider.Release(match.?);
    try std.testing.expectEqual(
        range.snapshot,
        TerminalTextRangeProvider.fromBase(match.?).snapshot,
    );
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 12, .end = 15 },
        TerminalTextRangeProvider.fromBase(match.?).range,
    );
}

test "TerminalTextRangeProvider finds Unicode text case-insensitively" {
    const document = "Ångström Σ\nångström σ";
    const expected_text = "ångström σ";
    var state_data = TestTerminalStateData{ .value_text = document };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, document),
        .{ .start = 0, .end = document.len },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    var match: ?*com.ITextRangeProvider = null;
    const needle = com.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral("ÅNGSTRÖM Σ")).?;
    defer com.SysFreeString(needle);
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.FindText(&range.base, needle, 1, 1, &match),
    );
    defer _ = TerminalTextRangeProvider.Release(match.?);

    const start = std.mem.lastIndexOf(u8, document, expected_text).?;
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = start, .end = start + expected_text.len },
        TerminalTextRangeProvider.fromBase(match.?).range,
    );
}

test "TerminalTextRangeProvider FindText reports allocation failures" {
    var state_data = TestTerminalStateData{ .value_text = "one TWO" };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, state_data.value_text),
        .{ .start = 0, .end = state_data.value_text.len },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    const needle = com.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral("two")).?;
    defer com.SysFreeString(needle);
    const original_alloc = range.alloc;
    defer range.alloc = original_alloc;

    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        range.alloc = failing.allocator();
        var match: ?*com.ITextRangeProvider = @ptrFromInt(0x10);
        try std.testing.expectEqual(
            com.E_OUTOFMEMORY,
            TerminalTextRangeProvider.FindText(&range.base, needle, 0, 1, &match),
        );
        try std.testing.expect(match == null);
    }
}

test "TerminalTextRangeProvider exact FindText consumes retained snapshot reference on child allocation failure" {
    var state_data = TestTerminalStateData{ .value_text = "one TWO" };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, state_data.value_text),
        .{ .start = 0, .end = state_data.value_text.len },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    const needle = com.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral("TWO")).?;
    defer com.SysFreeString(needle);
    const original_alloc = range.alloc;
    defer range.alloc = original_alloc;
    const references_before = range.snapshot.refcount.load(.monotonic);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    range.alloc = failing.allocator();

    var match: ?*com.ITextRangeProvider = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.E_OUTOFMEMORY,
        TerminalTextRangeProvider.FindText(&range.base, needle, 0, 0, &match),
    );
    try std.testing.expect(match == null);
    try std.testing.expectEqual(references_before, range.snapshot.refcount.load(.monotonic));
}

test "TerminalTextRangeProvider clamps endpoints copied from a newer snapshot" {
    var state_data = TestTerminalStateData{ .value_text = "old" };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var old_range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, "old"),
        .{ .start = 0, .end = 3 },
    );
    defer _ = TerminalTextRangeProvider.Release(&old_range.base);
    var new_range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, "newer snapshot"),
        .{ .start = 0, .end = 14 },
    );
    defer _ = TerminalTextRangeProvider.Release(&new_range.base);

    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.MoveEndpointByRange(
            &old_range.base,
            com.TextPatternRangeEndpoint_Start,
            &new_range.base,
            com.TextPatternRangeEndpoint_End,
        ),
    );
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 3, .end = 3 }, old_range.range);

    var text: ?[*:0]u16 = null;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.GetText(&old_range.base, -1, &text));
    defer com.SysFreeString(text);
}

test "terminal text range geometry returns screen rectangles for affected lines" {
    const text = "hello\nworld";
    const cells = [_]terminal_text.TerminalCellPosition{
        .{ .row = 0, .column = 0, .width = 1 },
        .{ .row = 0, .column = 1, .width = 1 },
        .{ .row = 0, .column = 2, .width = 1 },
        .{ .row = 0, .column = 3, .width = 1 },
        .{ .row = 0, .column = 4, .width = 1 },
        .{ .row = 0, .column = 4, .width = 0 },
        .{ .row = 1, .column = 0, .width = 1 },
        .{ .row = 1, .column = 1, .width = 1 },
        .{ .row = 1, .column = 2, .width = 1 },
        .{ .row = 1, .column = 3, .width = 1 },
        .{ .row = 1, .column = 4, .width = 1 },
    };
    const geometry = TerminalRangeGeometry{
        .cell_for_byte = @constCast(cells[0..]),
        .viewport_rows = 24,
        .viewport_columns = 80,
        .cell_width = 8,
        .cell_height = 16,
        .origin_x = 4,
        .origin_y = 6,
    };
    var values: [8]f64 = undefined;
    const count = terminalGridRectangleValues(
        text,
        .{ .start = 6, .end = 11 },
        geometry,
        .{ .x = 10, .y = 20 },
        &values,
    );

    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(f64, 14), values[0]);
    try std.testing.expectEqual(@as(f64, 42), values[1]);
    try std.testing.expectEqual(@as(f64, 40), values[2]);
    try std.testing.expectEqual(@as(f64, 16), values[3]);
    try std.testing.expectEqual(
        @as(usize, 0),
        terminalGridRectangleValues(text, .{ .start = 6, .end = 6 }, geometry, .{ .x = 10, .y = 20 }, &values),
    );
}

test "TerminalProvider RangeFromPoint returns a degenerate text range" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.RangeFromPoint(&p.text_iface, .{ .x = 0, .y = 0 }, &range),
    );
    defer _ = TerminalTextRangeProvider.Release(range.?);

    var out: ?[*:0]u16 = null;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.GetText(range.?, -1, &out));
    defer com.SysFreeString(out);
    try std.testing.expectEqual(@as(u32, 0), com.SysStringLen(out));
}

test "TerminalProvider RangeFromPoint returns document-coordinate offsets" {
    var state_data = TestTerminalStateData{
        .value_text = "scrollback\nvisible",
        .visible_value_text = "visible",
        .visible_range = .{ .start = 11, .end = 18 },
    };
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.RangeFromPoint(&p.text_iface, .{ .x = 0, .y = 0 }, &range),
    );
    defer _ = TerminalTextRangeProvider.Release(range.?);

    const concrete: *TerminalTextRangeProvider = @ptrCast(@alignCast(range.?));
    try std.testing.expectEqual(terminal_text.OffsetRange{ .start = 11, .end = 11 }, concrete.range);
    try std.testing.expectEqual(@as(u32, 1), state_data.value_calls);
    try std.testing.expectEqual(@as(u32, 1), state_data.visible_value_calls);
}

test "TerminalProvider point mapping uses client coordinates and UTF-8 boundaries" {
    const text = "A🔥B\nworld";
    const rect = RECT{ .left = 0, .top = 0, .right = 100, .bottom = 20 };

    try std.testing.expectEqual(
        @as(usize, 1),
        byteOffsetForClientPoint(text, rect, .{ .x = 35, .y = 0 }),
    );
    try std.testing.expectEqual(
        @as(usize, text.len),
        byteOffsetForClientPoint(text, rect, .{ .x = 100, .y = 19 }),
    );
}

test "terminal grid point mapping returns document offsets for visible cells" {
    const text = "old\nA🔥B\nlast";
    const cells = [_]terminal_text.TerminalCellPosition{
        .{ .row = -1, .column = 0, .width = 1 },
        .{ .row = -1, .column = 1, .width = 1 },
        .{ .row = -1, .column = 2, .width = 1 },
        .{ .row = -1, .column = 2, .width = 0 },
        .{ .row = 0, .column = 0, .width = 1 },
        .{ .row = 0, .column = 1, .width = 2 },
        .{ .row = 0, .column = 1, .width = 2 },
        .{ .row = 0, .column = 1, .width = 2 },
        .{ .row = 0, .column = 1, .width = 2 },
        .{ .row = 0, .column = 3, .width = 1 },
        .{ .row = 0, .column = 3, .width = 0 },
        .{ .row = 1, .column = 0, .width = 1 },
        .{ .row = 1, .column = 1, .width = 1 },
        .{ .row = 1, .column = 2, .width = 1 },
        .{ .row = 1, .column = 3, .width = 1 },
    };
    const geometry = TerminalRangeGeometry{
        .cell_for_byte = @constCast(cells[0..]),
        .viewport_rows = 2,
        .viewport_columns = 8,
        .cell_width = 10,
        .cell_height = 20,
        .origin_x = 4,
        .origin_y = 6,
    };

    try std.testing.expectEqual(
        @as(usize, 4),
        byteOffsetForTerminalGridPoint(text, .{ .start = 4, .end = text.len }, geometry, .{ .x = 4, .y = 6 }),
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        byteOffsetForTerminalGridPoint(text, .{ .start = 4, .end = text.len }, geometry, .{ .x = 24, .y = 10 }),
    );
    try std.testing.expectEqual(
        @as(usize, 10),
        byteOffsetForTerminalGridPoint(text, .{ .start = 4, .end = text.len }, geometry, .{ .x = 74, .y = 10 }),
    );
    try std.testing.expectEqual(
        @as(usize, 11),
        byteOffsetForTerminalGridPoint(text, .{ .start = 4, .end = text.len }, geometry, .{ .x = 4, .y = 30 }),
    );
}

test "safeI32FromUiaCoord rejects non-finite values and clamps range" {
    try std.testing.expectEqual(@as(?i32, null), safeI32FromUiaCoord(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?i32, null), safeI32FromUiaCoord(std.math.inf(f64)));
    try std.testing.expectEqual(
        @as(?i32, std.math.maxInt(i32)),
        safeI32FromUiaCoord(@as(f64, @floatFromInt(std.math.maxInt(i32))) + 1000.0),
    );
    try std.testing.expectEqual(
        @as(?i32, std.math.minInt(i32)),
        safeI32FromUiaCoord(@as(f64, @floatFromInt(std.math.minInt(i32))) - 1000.0),
    );
}

test "TerminalProvider does not duplicate terminal content through ValueValueProperty" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var value = com.VARIANT.empty();
    const hr = TerminalProvider.GetPropertyValue(&p.base, constants.UIA_ValueValuePropertyId, &value);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(com.VT_EMPTY, value.vt);
    try std.testing.expectEqual(@as(u32, 0), state_data.value_calls);
}

test "TerminalProvider HelpTextProperty reports user-facing terminal help" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var value = com.VARIANT.empty();
    const hr = TerminalProvider.GetPropertyValue(&p.base, constants.UIA_HelpTextPropertyId, &value);
    defer com.SysFreeString(value.value.bstr);

    const expected = std.unicode.utf8ToUtf16LeStringLiteral(
        "Read-only terminal text",
    );

    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(com.VT_BSTR, value.vt);
    try std.testing.expect(value.value.bstr != null);
    try std.testing.expectEqual(@as(u32, expected.len), com.SysStringLen(value.value.bstr));
    try std.testing.expectEqualSlices(u16, expected, value.value.bstr.?[0..expected.len]);
    try std.testing.expectEqual(@as(u32, 0), state_data.value_calls);
}

const TestTerminalStateData = struct {
    name_calls: u32 = 0,
    value_calls: u32 = 0,
    visible_value_calls: u32 = 0,
    visible_range_calls: u32 = 0,
    retains: u32 = 0,
    releases: u32 = 0,
    value_text: []const u8 = "hello\nworld",
    visible_value_text: []const u8 = "visible",
    visible_range: terminal_text.OffsetRange = .{ .start = 0, .end = 7 },
    caret_offset: usize = 0,
};

test "detached palette provider rejects late UIA name queries" {
    var callback_calls: u32 = 0;
    const callbacks = struct {
        fn name(ctx: *anyopaque, _: []u8) []const u8 {
            const calls: *u32 = @ptrCast(@alignCast(ctx));
            calls.* += 1;
            return "unsafe";
        }
    };
    const hwnd: com.HWND = @ptrFromInt(1);
    const provider = try PaletteListProvider.create(std.testing.allocator, hwnd, .{
        .ctx = @ptrCast(&callback_calls),
        .name = callbacks.name,
    });
    defer _ = PaletteListProvider.Release(&provider.base);
    provider.detach();
    provider.detach();

    var value = com.VARIANT.empty();
    const hr = PaletteListProvider.GetPropertyValue(
        &provider.base,
        constants.UIA_NamePropertyId,
        &value,
    );
    try std.testing.expect(hr != com.S_OK);
    try std.testing.expectEqual(@as(u32, 0), callback_calls);
}

test "detached terminal provider rejects late host provider queries" {
    var data = TestTerminalStateData{};
    const provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&data),
    );
    defer _ = TerminalProvider.Release(&provider.base);
    provider.detach();
    provider.detach();

    var host: ?*com.IRawElementProviderSimple = undefined;
    const hr = TerminalProvider.get_HostRawElementProvider(&provider.base, &host);
    try std.testing.expectEqual(@as(com.HRESULT, @bitCast(@as(u32, 0x80040201))), hr);
    try std.testing.expectEqual(@as(?*com.IRawElementProviderSimple, null), host);

    var active: com.BOOL = 1;
    var caret: ?*com.ITextRangeProvider = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        TerminalProvider.GetCaretRange(&provider.text2_iface, &active, &caret),
    );
    try std.testing.expectEqual(@as(com.BOOL, 0), active);
    try std.testing.expect(caret == null);
}

test "retained terminal range rejects queries after provider detach" {
    var state_data = TestTerminalStateData{};
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, state_data.value_text),
        .{ .start = 0, .end = state_data.value_text.len },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);
    provider.detach();

    var text: ?[*:0]u16 = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        TerminalTextRangeProvider.GetText(&range.base, -1, &text),
    );
    try std.testing.expect(text == null);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        TerminalTextRangeProvider.ScrollIntoView(&range.base, 1),
    );

    var clone: ?*com.ITextRangeProvider = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        TerminalTextRangeProvider.Clone(&range.base, &clone),
    );
    try std.testing.expect(clone == null);

    var children: ?*com.SAFEARRAY = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        TerminalTextRangeProvider.GetChildren(&range.base, &children),
    );
    try std.testing.expect(children == null);
}

test "TerminalTextRangeProvider reports unsupported mutation and scrolling honestly" {
    var state_data = TestTerminalStateData{};
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var range = try TerminalTextRangeProvider.createOwned(
        std.testing.allocator,
        provider,
        try std.testing.allocator.dupe(u8, state_data.value_text),
        .{ .start = 0, .end = state_data.value_text.len },
    );
    defer _ = TerminalTextRangeProvider.Release(&range.base);

    try std.testing.expectEqual(com.E_NOTIMPL, TerminalTextRangeProvider.Select(&range.base));
    try std.testing.expectEqual(com.E_NOTIMPL, TerminalTextRangeProvider.AddToSelection(&range.base));
    try std.testing.expectEqual(com.E_NOTIMPL, TerminalTextRangeProvider.RemoveFromSelection(&range.base));
    try std.testing.expectEqual(com.E_NOTIMPL, TerminalTextRangeProvider.ScrollIntoView(&range.base, 1));
}

fn testTerminalState(data: *TestTerminalStateData) TerminalState {
    const callbacks = struct {
        fn retain(ctx: *anyopaque) void {
            const d: *TestTerminalStateData = @ptrCast(@alignCast(ctx));
            d.retains += 1;
        }

        fn release(ctx: *anyopaque) void {
            const d: *TestTerminalStateData = @ptrCast(@alignCast(ctx));
            d.releases += 1;
        }

        fn name(ctx: *anyopaque, buf: []u8) []const u8 {
            const d: *TestTerminalStateData = @ptrCast(@alignCast(ctx));
            d.name_calls += 1;
            return std.fmt.bufPrint(buf, "terminal {d}", .{d.name_calls}) catch "";
        }

        fn value(ctx: *anyopaque, alloc: std.mem.Allocator) ![]u8 {
            const d: *TestTerminalStateData = @ptrCast(@alignCast(ctx));
            d.value_calls += 1;
            return try alloc.dupe(u8, d.value_text);
        }

        fn visibleValue(ctx: *anyopaque, alloc: std.mem.Allocator) ![]u8 {
            const d: *TestTerminalStateData = @ptrCast(@alignCast(ctx));
            d.visible_value_calls += 1;
            return try alloc.dupe(u8, d.visible_value_text);
        }

        fn visibleRange(ctx: *anyopaque, _: std.mem.Allocator) !terminal_text.OffsetRange {
            const d: *TestTerminalStateData = @ptrCast(@alignCast(ctx));
            d.visible_range_calls += 1;
            return d.visible_range;
        }

        fn snapshot(ctx: *anyopaque, alloc: std.mem.Allocator) !TerminalSnapshot {
            const d: *TestTerminalStateData = @ptrCast(@alignCast(ctx));
            d.value_calls += 1;
            d.visible_value_calls += 1;
            d.visible_range_calls += 1;

            const document_text = try alloc.dupe(u8, d.value_text);
            errdefer alloc.free(document_text);
            const visible_text = try alloc.dupe(u8, d.visible_value_text);
            return .{
                .document_text = document_text,
                .visible_text = visible_text,
                .visible_range = d.visible_range,
                .caret_offset = d.caret_offset,
            };
        }

        fn focused(ctx: *anyopaque) bool {
            _ = ctx;
            return true;
        }
    };
    return .{
        .ctx = @ptrCast(data),
        .retain = callbacks.retain,
        .release = callbacks.release,
        .name = callbacks.name,
        .value = callbacks.value,
        .visible_value = callbacks.visibleValue,
        .visible_range = callbacks.visibleRange,
        .snapshot = callbacks.snapshot,
        .focused = callbacks.focused,
    };
}
