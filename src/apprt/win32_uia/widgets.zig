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
//!     ControlType=Text and exposes terminal content through TextPattern.
//!
//! The owner-drawn palette list is a fragment root. Its rows are ephemeral
//! fragment/SelectionItem providers backed by live widget state; native HWND
//! controls continue to use the system provider.

const std = @import("std");
const com = @import("com.zig");
const constants = @import("constants.zig");
const events = @import("events.zig");
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

const GUITHREADINFO = extern struct {
    cbSize: u32,
    flags: u32,
    hwndActive: ?com.HWND,
    hwndFocus: ?com.HWND,
    hwndCapture: ?com.HWND,
    hwndMenuOwner: ?com.HWND,
    hwndMoveSize: ?com.HWND,
    hwndCaret: ?com.HWND,
    rcCaret: RECT,
};

extern "user32" fn GetClientRect(hWnd: com.HWND, lpRect: *RECT) callconv(.winapi) com.BOOL;
extern "user32" fn GetDlgCtrlID(hWnd: com.HWND) callconv(.winapi) i32;
extern "user32" fn GetParent(hWnd: com.HWND) callconv(.winapi) ?com.HWND;
extern "user32" fn IsWindow(hWnd: com.HWND) callconv(.winapi) com.BOOL;
extern "user32" fn IsWindowEnabled(hWnd: com.HWND) callconv(.winapi) com.BOOL;
extern "user32" fn IsWindowVisible(hWnd: com.HWND) callconv(.winapi) com.BOOL;
extern "user32" fn IsChild(hWndParent: com.HWND, hWnd: com.HWND) callconv(.winapi) com.BOOL;
extern "user32" fn GetGUIThreadInfo(idThread: u32, pgui: *GUITHREADINFO) callconv(.winapi) com.BOOL;
extern "user32" fn GetWindowThreadProcessId(hWnd: com.HWND, lpdwProcessId: ?*u32) callconv(.winapi) u32;
extern "user32" fn SendMessageW(hWnd: com.HWND, Msg: u32, wParam: com.WPARAM, lParam: com.LPARAM) callconv(.winapi) com.LRESULT;
extern "user32" fn SendMessageTimeoutW(
    hWnd: com.HWND,
    Msg: u32,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    fuFlags: u32,
    uTimeout: u32,
    lpdwResult: *usize,
) callconv(.winapi) com.LRESULT;
extern "user32" fn PostMessageW(hWnd: com.HWND, Msg: u32, wParam: com.WPARAM, lParam: com.LPARAM) callconv(.winapi) com.BOOL;
extern "user32" fn ScreenToClient(hWnd: com.HWND, lpPoint: *POINT) callconv(.winapi) com.BOOL;
extern "user32" fn ClientToScreen(hWnd: com.HWND, lpPoint: *POINT) callconv(.winapi) com.BOOL;
extern "kernel32" fn CompareStringOrdinal(
    lpString1: [*]const u16,
    cchCount1: i32,
    lpString2: [*]const u16,
    cchCount2: i32,
    bIgnoreCase: com.BOOL,
) callconv(.winapi) i32;

fn windowVisibilityIsOffscreen(visible: com.BOOL) bool {
    return visible == 0;
}

fn settingsControlIsOffscreen(visible: com.BOOL, viewport_fully_clipped: bool) bool {
    return windowVisibilityIsOffscreen(visible) or viewport_fully_clipped;
}

fn hwndHasKeyboardFocus(hwnd: com.HWND) bool {
    const thread_id = GetWindowThreadProcessId(hwnd, null);
    if (thread_id == 0) return false;
    var info: GUITHREADINFO = .{
        .cbSize = @sizeOf(GUITHREADINFO),
        .flags = 0,
        .hwndActive = null,
        .hwndFocus = null,
        .hwndCapture = null,
        .hwndMenuOwner = null,
        .hwndMoveSize = null,
        .hwndCaret = null,
        .rcCaret = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    if (GetGUIThreadInfo(thread_id, &info) == 0) return false;
    const focused = info.hwndFocus orelse return false;
    return focused == hwnd or IsChild(hwnd, focused) != 0;
}

const WM_COMMAND: u32 = 0x0111;
const SMTO_BLOCK: u32 = 0x0001;
const SMTO_ABORTIFHUNG: u32 = 0x0002;
const settings_selection_timeout_ms: u32 = 2000;

/// Asynchronously route a native BUTTON activation to its parent. BM_CLICK
/// can silently fail while the top-level window is inactive; UIA Invoke must
/// remain operable in that state without blocking its caller.
fn postButtonClicked(hwnd: com.HWND) com.HRESULT {
    const parent = GetParent(hwnd) orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
    const control_id = GetDlgCtrlID(hwnd);
    if (control_id <= 0) return com.E_INVALIDARG;
    return if (PostMessageW(
        parent,
        WM_COMMAND,
        @intCast(control_id),
        @bitCast(@intFromPtr(hwnd)),
    ) != 0) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
}

/// SelectionItem.Select is synchronous: once it returns, the provider's
/// selected state must already reflect the request. SendMessageTimeout
/// marshals to the owning UI thread without hanging assistive technology on
/// an unresponsive settings thread.
fn sendButtonClicked(hwnd: com.HWND) com.HRESULT {
    const parent = GetParent(hwnd) orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
    const control_id = GetDlgCtrlID(hwnd);
    if (control_id <= 0) return com.E_INVALIDARG;
    var ignored: usize = 0;
    return if (SendMessageTimeoutW(
        parent,
        WM_COMMAND,
        @intCast(control_id),
        @bitCast(@intFromPtr(hwnd)),
        SMTO_BLOCK | SMTO_ABORTIFHUNG,
        settings_selection_timeout_ms,
        &ignored,
    ) != 0) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
}

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
    localized_control_type: []const u8 = "command palette matches",
    keyboard_focusable: bool = false,
    focused: ?*const fn (ctx: *anyopaque) bool = null,
    row_count: ?*const fn (ctx: *anyopaque) usize = null,
    selected_index: ?*const fn (ctx: *anyopaque) ?usize = null,
    row_name: ?*const fn (ctx: *anyopaque, index: usize, buf: []u8) []const u8 = null,
    row_enabled: ?*const fn (ctx: *anyopaque, index: usize) bool = null,
    row_id: ?*const fn (ctx: *anyopaque, index: usize) u64 = null,
    select_row: ?*const fn (ctx: *anyopaque, index: usize) void = null,
    geometry: ?*const fn (ctx: *anyopaque) ?PaletteListGeometry = null,
    use_com_threading: bool = false,
};

/// Live state queried by the quick-select overlay provider. The indirection
/// keeps this module independent of the Win32 Surface implementation.
pub const QuickSelectState = struct {
    ctx: *anyopaque,
    name: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
    use_com_threading: bool = false,
};

pub const PaletteListGeometry = struct {
    bounds: com.UiaRect,
    first_visible: usize,
    visible_count: usize,
    row_height: f64,
};

pub const TerminalState = struct {
    pub const Role = enum { terminal, edit };

    ctx: *anyopaque,
    retain: ?*const fn (ctx: *anyopaque) void = null,
    release: ?*const fn (ctx: *anyopaque) void = null,
    name: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
    value: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8,
    snapshot: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!TerminalSnapshot = null,
    focused: *const fn (ctx: *anyopaque) bool,
    role: Role = .terminal,
    /// The provider was created on a confirmed STA and UI Automation may
    /// marshal callbacks back to that owning apartment.
    use_com_threading: bool = false,
    set_value: ?*const fn (ctx: *anyopaque, value: []const u8) anyerror!void = null,
    select_range: ?*const fn (
        ctx: *anyopaque,
        snapshot_text: []const u8,
        range: terminal_text.OffsetRange,
    ) anyerror!void = null,
};

pub const TerminalSnapshot = struct {
    document_text: []u8,
    visible_text: []u8,
    visible_range: terminal_text.OffsetRange,
    caret_offset: usize = 0,
    selection_range: terminal_text.OffsetRange = .{ .start = 0, .end = 0 },
    terminal_selection_range: ?terminal_text.OffsetRange = null,
    terminal_selection_active_offset: ?usize = null,
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

/// Minimal provider for the focusable, owner-drawn quick-select overlay.
pub const QuickSelectProvider = struct {
    base: com.IRawElementProviderSimple,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state: QuickSelectState,
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),

    const vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .get_ProviderOptions = get_ProviderOptions,
        .GetPatternProvider = GetPatternProvider,
        .GetPropertyValue = GetPropertyValue,
        .get_HostRawElementProvider = get_HostRawElementProvider,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        state: QuickSelectState,
    ) !*QuickSelectProvider {
        const self = try alloc.create(QuickSelectProvider);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .state = state,
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    pub fn detach(self: *QuickSelectProvider) void {
        self.detached.store(true, .release);
    }

    pub fn disconnect(self: *QuickSelectProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        const hr = com.UiaDisconnectProvider(&self.base);
        if (hr == com.S_OK) self.disconnected.store(true, .release);
        return hr;
    }

    pub fn raiseNameChanged(self: *QuickSelectProvider) void {
        if (self.detached.load(.acquire)) return;
        events.raiseNameChanged(&self.base);
    }

    pub fn raiseFocusChanged(self: *QuickSelectProvider) void {
        if (self.detached.load(.acquire)) return;
        events.raiseFocusChanged(&self.base);
    }

    fn fromBase(base: *com.IRawElementProviderSimple) *QuickSelectProvider {
        return @fieldParentPtr("base", base);
    }

    pub fn QueryInterface(
        base: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(base);
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        return com.E_NOINTERFACE;
    }

    pub fn AddRef(base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(base).refcount.fetchAdd(1, .monotonic) + 1;
    }

    pub fn Release(base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(base);
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }

    fn get_ProviderOptions(
        base: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(base);
        out.* = com.ProviderOptions_ServerSideProvider |
            (if (self.state.use_com_threading) com.ProviderOptions_UseComThreading else 0);
        return com.S_OK;
    }

    fn GetPatternProvider(
        base: *com.IRawElementProviderSimple,
        _: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return if (fromBase(base).detached.load(.acquire))
            com.UIA_E_ELEMENTNOTAVAILABLE
        else
            com.S_OK;
    }

    fn GetPropertyValue(
        base: *com.IRawElementProviderSimple,
        property: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(base);
        out.* = com.VARIANT.empty();
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;

        switch (property) {
            constants.UIA_ControlTypePropertyId => {
                out.* = com.VARIANT.fromI4(constants.UIA_ListControlTypeId);
            },
            constants.UIA_NamePropertyId => {
                var buf: [256]u8 = undefined;
                const bstr = allocBstrFromUtf8(
                    self.alloc,
                    self.state.name(self.state.ctx, &buf),
                ) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_LocalizedControlTypePropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("quick select targets");
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
            constants.UIA_IsKeyboardFocusablePropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_HasKeyboardFocusPropertyId => {
                out.* = com.VARIANT.fromBool(hwndHasKeyboardFocus(self.hwnd));
            },
            else => {},
        }
        return com.S_OK;
    }

    fn get_HostRawElementProvider(
        base: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(base);
        if (self.detached.load(.acquire)) {
            out.* = null;
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        }
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }
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
        events.raiseSelectionItemSelected(&row.base);
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
        self_base: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = com.ProviderOptions_ServerSideProvider |
            (if (self.state.use_com_threading) com.ProviderOptions_UseComThreading else 0);
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
                const bstr = allocBstrFromUtf8(
                    self.alloc,
                    self.state.localized_control_type,
                ) orelse return com.E_OUTOFMEMORY;
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
            constants.UIA_IsKeyboardFocusablePropertyId => {
                out.* = com.VARIANT.fromBool(self.state.keyboard_focusable);
            },
            constants.UIA_HasKeyboardFocusPropertyId => {
                const focused = if (self.state.focused) |callback|
                    callback(self.state.ctx)
                else
                    false;
                out.* = com.VARIANT.fromBool(focused);
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
        out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        if (!self.isAvailable()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.geometry()) |value| out.* = value.bounds;
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
        .SetFocus = PaletteRowProvider.SetFocus,
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
    pub fn Release(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(p).release();
    }
    fn FragmentRelease(p: *com.IRawElementProviderFragment) callconv(.winapi) u32 {
        return fromFragment(p).release();
    }
    fn SelectionRelease(p: *com.ISelectionItemProvider) callconv(.winapi) u32 {
        return fromSelection(p).release();
    }
    fn getProviderOptions(p: *com.IRawElementProviderSimple, out: *i32) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = com.ProviderOptions_ServerSideProvider |
            (if (self.parent.state.use_com_threading) com.ProviderOptions_UseComThreading else 0);
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
        out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.parent.rowBounds(self.index)) |bounds| out.* = bounds;
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
        out.* = 0;
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

pub const settings_section_count = 7;

/// Stable provider for native STATIC controls that this custom settings
/// window otherwise exposes as generic Panes through the system bridge.
pub const SettingsControlProvider = struct {
    pub const Role = enum {
        text,
        edit,
        combo_box,
        check_box,
        button,
    };

    base: com.IRawElementProviderSimple,
    value_iface: com.IValueProvider,
    invoke_iface: com.IInvokeProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    role: Role,
    name: ?[]const u8,
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),
    viewport_fully_clipped: std.atomic.Value(bool),

    const vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .get_ProviderOptions = getProviderOptions,
        .GetPatternProvider = GetPatternProvider,
        .GetPropertyValue = GetPropertyValue,
        .get_HostRawElementProvider = getHostRawElementProvider,
    };

    const value_vtbl: com.IValueProviderVtbl = .{
        .QueryInterface = ValueQueryInterface,
        .AddRef = ValueAddRef,
        .Release = ValueRelease,
        .SetValue = SetValue,
        .get_Value = GetValue,
        .get_IsReadOnly = GetIsReadOnly,
    };

    const invoke_vtbl: com.IInvokeProviderVtbl = .{
        .QueryInterface = InvokeQueryInterface,
        .AddRef = InvokeAddRef,
        .Release = InvokeRelease,
        .Invoke = Invoke,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        role: Role,
        name: ?[]const u8,
    ) !*SettingsControlProvider {
        const self = try alloc.create(SettingsControlProvider);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .value_iface = .{ .vtbl = &value_vtbl },
            .invoke_iface = .{ .vtbl = &invoke_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .role = role,
            .name = name,
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
            .viewport_fully_clipped = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    pub fn detach(self: *SettingsControlProvider) void {
        self.detached.store(true, .release);
    }

    pub fn setViewportFullyClipped(self: *SettingsControlProvider, fully_clipped: bool) void {
        self.viewport_fully_clipped.store(fully_clipped, .release);
    }

    pub fn raiseFocusChanged(self: *SettingsControlProvider) void {
        if (!self.available()) return;
        events.raiseFocusChanged(&self.base);
    }

    pub fn disconnect(self: *SettingsControlProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        const hr = com.UiaDisconnectProvider(&self.base);
        // Deferred settings teardown runs after native child destruction.
        // UIA reports E_INVALIDARG when that HWND/provider registration is
        // already gone; the detached provider is nevertheless terminal.
        if (hr == com.S_OK or hr == com.E_INVALIDARG) {
            self.disconnected.store(true, .release);
            return com.S_OK;
        }
        return hr;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *SettingsControlProvider {
        return @fieldParentPtr("base", p);
    }

    fn fromValue(p: *com.IValueProvider) *SettingsControlProvider {
        return @fieldParentPtr("value_iface", p);
    }

    fn fromInvoke(p: *com.IInvokeProvider) *SettingsControlProvider {
        return @fieldParentPtr("invoke_iface", p);
    }

    fn available(self: *const SettingsControlProvider) bool {
        return !self.detached.load(.acquire) and IsWindow(self.hwnd) != 0;
    }

    fn QueryInterface(
        p: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        const self = fromBase(p);
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(p);
        } else if (self.role == .edit and iidEqual(iid, &com.IID_IValueProvider)) {
            out.* = @ptrCast(&self.value_iface);
        } else if (self.role == .button and iidEqual(iid, &com.IID_IInvokeProvider)) {
            out.* = @ptrCast(&self.invoke_iface);
        } else return com.E_NOINTERFACE;
        _ = AddRef(p);
        return com.S_OK;
    }

    fn ValueQueryInterface(
        p: *com.IValueProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromValue(p).base, iid, out);
    }

    fn InvokeQueryInterface(
        p: *com.IInvokeProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromInvoke(p).base, iid, out);
    }

    fn AddRef(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(p).refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn ValueAddRef(p: *com.IValueProvider) callconv(.winapi) u32 {
        return AddRef(&fromValue(p).base);
    }

    fn InvokeAddRef(p: *com.IInvokeProvider) callconv(.winapi) u32 {
        return AddRef(&fromInvoke(p).base);
    }

    pub fn Release(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(p);
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }

    fn ValueRelease(p: *com.IValueProvider) callconv(.winapi) u32 {
        return Release(&fromValue(p).base);
    }

    fn InvokeRelease(p: *com.IInvokeProvider) callconv(.winapi) u32 {
        return Release(&fromInvoke(p).base);
    }

    fn getProviderOptions(
        _: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider | com.ProviderOptions_UseComThreading;
        return com.S_OK;
    }

    fn GetPatternProvider(
        p: *com.IRawElementProviderSimple,
        pattern_id: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.role == .text) return com.S_OK;
        if (self.role == .edit and pattern_id == constants.UIA_ValuePatternId) {
            out.* = @ptrCast(&self.value_iface);
            _ = AddRef(&self.base);
            return com.S_OK;
        }
        if (self.role == .button and pattern_id == constants.UIA_InvokePatternId) {
            out.* = @ptrCast(&self.invoke_iface);
            _ = AddRef(&self.base);
            return com.S_OK;
        }
        var host: ?*com.IRawElementProviderSimple = null;
        const host_hr = com.UiaHostProviderFromHwnd(self.hwnd, &host);
        if (host_hr != com.S_OK or host == null) return host_hr;
        defer _ = host.?.vtbl.Release(host.?);
        return host.?.vtbl.GetPatternProvider(host.?, pattern_id, out);
    }

    fn GetPropertyValue(
        p: *com.IRawElementProviderSimple,
        property: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = com.VARIANT.empty();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        switch (property) {
            constants.UIA_ControlTypePropertyId => out.* = com.VARIANT.fromI4(switch (self.role) {
                .text => constants.UIA_TextControlTypeId,
                .edit => constants.UIA_EditControlTypeId,
                .combo_box => constants.UIA_ComboBoxControlTypeId,
                .check_box => constants.UIA_CheckBoxControlTypeId,
                .button => constants.UIA_ButtonControlTypeId,
            }),
            constants.UIA_NamePropertyId => {
                if (self.name) |name| {
                    const bstr = allocBstrFromUtf8(self.alloc, name) orelse return com.E_OUTOFMEMORY;
                    out.* = com.VARIANT.fromBstr(bstr);
                } else {
                    const length = @max(0, com.GetWindowTextLengthW(self.hwnd));
                    const buffer = self.alloc.alloc(u16, @as(usize, @intCast(length)) + 1) catch return com.E_OUTOFMEMORY;
                    defer self.alloc.free(buffer);
                    const copied = com.GetWindowTextW(self.hwnd, buffer.ptr, @intCast(buffer.len));
                    const bstr = com.SysAllocStringLen(buffer.ptr, @intCast(@max(0, copied))) orelse return com.E_OUTOFMEMORY;
                    out.* = com.VARIANT.fromBstr(bstr);
                }
            },
            constants.UIA_ValueValuePropertyId => if (self.role == .edit) {
                const value = self.allocValueBstr() orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(value);
            },
            constants.UIA_ValueIsReadOnlyPropertyId => if (self.role == .edit) {
                out.* = com.VARIANT.fromBool(false);
            },
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_IsEnabledPropertyId => out.* = com.VARIANT.fromBool(IsWindowEnabled(self.hwnd) != 0),
            constants.UIA_IsKeyboardFocusablePropertyId => out.* = com.VARIANT.fromBool(self.role != .text),
            constants.UIA_HasKeyboardFocusPropertyId => out.* = com.VARIANT.fromBool(
                self.role != .text and hwndHasKeyboardFocus(self.hwnd),
            ),
            constants.UIA_IsOffscreenPropertyId => out.* = com.VARIANT.fromBool(settingsControlIsOffscreen(
                IsWindowVisible(self.hwnd),
                self.viewport_fully_clipped.load(.acquire),
            )),
            else => {},
        }
        return com.S_OK;
    }

    fn allocValueBstr(self: *SettingsControlProvider) com.BSTR {
        const length = @max(0, com.GetWindowTextLengthW(self.hwnd));
        const buffer = self.alloc.alloc(u16, @as(usize, @intCast(length)) + 1) catch return null;
        defer self.alloc.free(buffer);
        const copied = com.GetWindowTextW(self.hwnd, buffer.ptr, @intCast(buffer.len));
        return com.SysAllocStringLen(buffer.ptr, @intCast(@max(0, copied)));
    }

    fn setValuePrecondition(provider_available: bool, role: Role, enabled: bool) com.HRESULT {
        if (!provider_available) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (role != .edit) return com.UIA_E_INVALIDOPERATION;
        if (!enabled) return com.UIA_E_ELEMENTNOTENABLED;
        return com.S_OK;
    }

    fn invokePrecondition(provider_available: bool, role: Role, enabled: bool) com.HRESULT {
        if (!provider_available) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (role != .button) return com.UIA_E_INVALIDOPERATION;
        if (!enabled) return com.UIA_E_ELEMENTNOTENABLED;
        return com.S_OK;
    }

    fn Invoke(p: *com.IInvokeProvider) callconv(.winapi) com.HRESULT {
        const self = fromInvoke(p);
        const precondition = invokePrecondition(
            self.available(),
            self.role,
            IsWindowEnabled(self.hwnd) != 0,
        );
        if (precondition != com.S_OK) return precondition;
        // IInvokeProvider.Invoke must return without waiting for the UI
        // thread. BM_CLICK can silently fail for an inactive top-level
        // window, which is exactly when assistive technology may invoke a
        // surviving Settings window after its terminal owner closes. Marshal
        // the native BN_CLICKED command directly to the parent instead.
        return postButtonClicked(self.hwnd);
    }

    fn SetValue(
        p: *com.IValueProvider,
        value: [*:0]const u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(p);
        const precondition = setValuePrecondition(
            self.available(),
            self.role,
            IsWindowEnabled(self.hwnd) != 0,
        );
        if (precondition != com.S_OK) return precondition;
        return if (com.SetWindowTextW(self.hwnd, value) != 0) com.S_OK else com.E_INVALIDARG;
    }

    fn GetValue(
        p: *com.IValueProvider,
        out: *com.BSTR,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.role != .edit) return com.UIA_E_INVALIDOPERATION;
        out.* = self.allocValueBstr() orelse return com.E_OUTOFMEMORY;
        return com.S_OK;
    }

    fn GetIsReadOnly(
        p: *com.IValueProvider,
        out: *com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(p);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return if (self.role == .edit) com.S_OK else com.UIA_E_INVALIDOPERATION;
    }

    fn getHostRawElementProvider(
        p: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }
};

pub fn returnSettingsControlProvider(
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    provider: *SettingsControlProvider,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;
    if (!provider.available() or provider.hwnd != hwnd) return null;
    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

/// Selection container for the settings window's native section radio buttons.
/// The section providers retain this object; it only borrows their pointers while
/// attached, so teardown cannot form a COM reference cycle.
pub const SettingsSectionGroupProvider = struct {
    base: com.IRawElementProviderSimple,
    selection_iface: com.ISelectionProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    sections_mutex: std.Thread.Mutex,
    sections: [settings_section_count]?*SettingsSectionProvider,
    selected_index: std.atomic.Value(u8),
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),

    const simple_vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .get_ProviderOptions = getProviderOptions,
        .GetPatternProvider = GetPatternProvider,
        .GetPropertyValue = GetPropertyValue,
        .get_HostRawElementProvider = getHostRawElementProvider,
    };

    const selection_vtbl: com.ISelectionProviderVtbl = .{
        .QueryInterface = SelectionQueryInterface,
        .AddRef = SelectionAddRef,
        .Release = SelectionRelease,
        .GetSelection = GetSelection,
        .get_CanSelectMultiple = GetCanSelectMultiple,
        .get_IsSelectionRequired = GetIsSelectionRequired,
    };

    pub fn create(alloc: std.mem.Allocator, hwnd: com.HWND) !*SettingsSectionGroupProvider {
        const self = try alloc.create(SettingsSectionGroupProvider);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .selection_iface = .{ .vtbl = &selection_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .sections_mutex = .{},
            .sections = [_]?*SettingsSectionProvider{null} ** settings_section_count,
            .selected_index = .init(std.math.maxInt(u8)),
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    pub fn setSection(self: *SettingsSectionGroupProvider, index: usize, section: *SettingsSectionProvider) void {
        self.sections_mutex.lock();
        defer self.sections_mutex.unlock();
        if (index < self.sections.len) self.sections[index] = section;
    }

    pub fn setSelected(self: *SettingsSectionGroupProvider, index: usize) void {
        self.selected_index.store(@intCast(index), .release);
    }

    pub fn detach(self: *SettingsSectionGroupProvider) void {
        self.detached.store(true, .release);
        self.selected_index.store(std.math.maxInt(u8), .release);
        self.sections_mutex.lock();
        defer self.sections_mutex.unlock();
        self.sections = [_]?*SettingsSectionProvider{null} ** settings_section_count;
    }

    pub fn disconnect(self: *SettingsSectionGroupProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        const hr = com.UiaDisconnectProvider(&self.base);
        if (hr == com.S_OK or hr == com.E_INVALIDARG) {
            self.disconnected.store(true, .release);
            return com.S_OK;
        }
        return hr;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *SettingsSectionGroupProvider {
        return @fieldParentPtr("base", p);
    }

    fn fromSelection(p: *com.ISelectionProvider) *SettingsSectionGroupProvider {
        return @fieldParentPtr("selection_iface", p);
    }

    fn available(self: *const SettingsSectionGroupProvider) bool {
        return !self.detached.load(.acquire) and IsWindow(self.hwnd) != 0;
    }

    fn queryInterface(
        self: *SettingsSectionGroupProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
        } else if (iidEqual(iid, &com.IID_ISelectionProvider)) {
            out.* = @ptrCast(&self.selection_iface);
        } else {
            return com.E_NOINTERFACE;
        }
        _ = self.refcount.fetchAdd(1, .monotonic);
        return com.S_OK;
    }

    fn QueryInterface(
        p: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromBase(p).queryInterface(iid, out);
    }

    fn AddRef(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(p).refcount.fetchAdd(1, .monotonic) + 1;
    }

    pub fn Release(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(p);
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }

    fn getProviderOptions(
        _: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider | com.ProviderOptions_UseComThreading;
        return com.S_OK;
    }

    fn GetPatternProvider(
        p: *com.IRawElementProviderSimple,
        pattern_id: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (pattern_id == constants.UIA_SelectionPatternId) {
            out.* = @ptrCast(&self.selection_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
        }
        return com.S_OK;
    }

    fn GetPropertyValue(
        p: *com.IRawElementProviderSimple,
        property: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = com.VARIANT.empty();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        switch (property) {
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_IsEnabledPropertyId => out.* = com.VARIANT.fromBool(IsWindowEnabled(self.hwnd) != 0),
            constants.UIA_IsOffscreenPropertyId => out.* = com.VARIANT.fromBool(windowVisibilityIsOffscreen(IsWindowVisible(self.hwnd))),
            else => {},
        }
        return com.S_OK;
    }

    fn getHostRawElementProvider(
        p: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }

    fn SelectionQueryInterface(
        p: *com.ISelectionProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromSelection(p).queryInterface(iid, out);
    }

    fn SelectionAddRef(p: *com.ISelectionProvider) callconv(.winapi) u32 {
        return fromSelection(p).refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn SelectionRelease(p: *com.ISelectionProvider) callconv(.winapi) u32 {
        return Release(&fromSelection(p).base);
    }

    fn GetSelection(
        p: *com.ISelectionProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        var selected: ?*SettingsSectionProvider = null;
        self.sections_mutex.lock();
        if (self.detached.load(.acquire)) {
            self.sections_mutex.unlock();
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        }
        const selected_index: usize = @intCast(self.selected_index.load(.acquire));
        if (selected_index < self.sections.len) {
            selected = self.sections[selected_index];
            if (selected) |section| _ = SettingsSectionProvider.AddRef(&section.base);
        }
        self.sections_mutex.unlock();
        defer {
            if (selected) |section| _ = SettingsSectionProvider.Release(&section.base);
        }
        const array = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, if (selected == null) 0 else 1) orelse
            return com.E_OUTOFMEMORY;
        if (selected) |section| {
            var array_index: i32 = 0;
            if (com.SafeArrayPutElement(array, &array_index, @ptrCast(&section.base)) != com.S_OK) {
                _ = com.SafeArrayDestroy(array);
                return com.E_OUTOFMEMORY;
            }
        }
        out.* = array;
        return com.S_OK;
    }

    fn GetCanSelectMultiple(p: *com.ISelectionProvider, out: *com.BOOL) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.S_OK;
    }

    fn GetIsSelectionRequired(p: *com.ISelectionProvider, out: *com.BOOL) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = 1;
        return com.S_OK;
    }
};

pub fn returnSettingsSectionGroupProvider(
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    provider: *SettingsSectionGroupProvider,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;
    if (!provider.available() or provider.hwnd != hwnd) return null;
    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

/// Explicit provider for the settings window's native section radio buttons.
/// The system UIA bridge reports these push-like BUTTON HWNDs as generic Panes,
/// so Narrator otherwise loses both their radio role and selection semantics.
pub const SettingsSectionProvider = struct {
    base: com.IRawElementProviderSimple,
    selection_iface: com.ISelectionItemProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    name: []const u8,
    index: u8,
    container: *SettingsSectionGroupProvider,
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),

    const simple_vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .get_ProviderOptions = getProviderOptions,
        .GetPatternProvider = GetPatternProvider,
        .GetPropertyValue = GetPropertyValue,
        .get_HostRawElementProvider = getHostRawElementProvider,
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

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        name: []const u8,
        index: usize,
        container: *SettingsSectionGroupProvider,
    ) !*SettingsSectionProvider {
        const self = try alloc.create(SettingsSectionProvider);
        _ = SettingsSectionGroupProvider.AddRef(&container.base);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .selection_iface = .{ .vtbl = &selection_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .name = name,
            .index = @intCast(index),
            .container = container,
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    pub fn detach(self: *SettingsSectionProvider) void {
        self.detached.store(true, .release);
    }

    pub fn disconnect(self: *SettingsSectionProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        const hr = com.UiaDisconnectProvider(&self.base);
        if (hr == com.S_OK or hr == com.E_INVALIDARG) {
            self.disconnected.store(true, .release);
            return com.S_OK;
        }
        return hr;
    }

    pub fn raiseSelected(self: *SettingsSectionProvider) void {
        if (!self.available()) return;
        events.raiseSelectionItemSelected(&self.base);
    }

    pub fn raiseFocusChanged(self: *SettingsSectionProvider) void {
        if (!self.available()) return;
        events.raiseFocusChanged(&self.base);
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *SettingsSectionProvider {
        return @fieldParentPtr("base", p);
    }

    fn fromSelection(p: *com.ISelectionItemProvider) *SettingsSectionProvider {
        return @fieldParentPtr("selection_iface", p);
    }

    fn available(self: *const SettingsSectionProvider) bool {
        return !self.detached.load(.acquire) and IsWindow(self.hwnd) != 0;
    }

    fn queryInterface(
        self: *SettingsSectionProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
        } else if (iidEqual(iid, &com.IID_ISelectionItemProvider)) {
            out.* = @ptrCast(&self.selection_iface);
        } else {
            return com.E_NOINTERFACE;
        }
        _ = self.refcount.fetchAdd(1, .monotonic);
        return com.S_OK;
    }

    fn QueryInterface(
        p: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromBase(p).queryInterface(iid, out);
    }

    fn AddRef(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(p).refcount.fetchAdd(1, .monotonic) + 1;
    }

    pub fn Release(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(p);
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            _ = SettingsSectionGroupProvider.Release(&self.container.base);
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }

    fn getProviderOptions(
        _: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider | com.ProviderOptions_UseComThreading;
        return com.S_OK;
    }

    fn GetPatternProvider(
        p: *com.IRawElementProviderSimple,
        pattern_id: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (pattern_id == constants.UIA_SelectionItemPatternId) {
            out.* = @ptrCast(&self.selection_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
        }
        return com.S_OK;
    }

    fn GetPropertyValue(
        p: *com.IRawElementProviderSimple,
        property: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = com.VARIANT.empty();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        switch (property) {
            constants.UIA_ControlTypePropertyId => out.* = com.VARIANT.fromI4(constants.UIA_RadioButtonControlTypeId),
            constants.UIA_NamePropertyId => {
                const bstr = allocBstrFromUtf8(self.alloc, self.name) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            constants.UIA_IsKeyboardFocusablePropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_IsEnabledPropertyId => out.* = com.VARIANT.fromBool(IsWindowEnabled(self.hwnd) != 0),
            constants.UIA_HasKeyboardFocusPropertyId => out.* = com.VARIANT.fromBool(hwndHasKeyboardFocus(self.hwnd)),
            constants.UIA_IsOffscreenPropertyId => out.* = com.VARIANT.fromBool(windowVisibilityIsOffscreen(IsWindowVisible(self.hwnd))),
            constants.UIA_SelectionItemIsSelectedPropertyId => out.* = com.VARIANT.fromBool(self.isSelected()),
            else => {},
        }
        return com.S_OK;
    }

    fn getHostRawElementProvider(
        p: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }

    fn SelectionQueryInterface(
        p: *com.ISelectionItemProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromSelection(p).queryInterface(iid, out);
    }

    fn SelectionAddRef(p: *com.ISelectionItemProvider) callconv(.winapi) u32 {
        return fromSelection(p).refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn SelectionRelease(p: *com.ISelectionItemProvider) callconv(.winapi) u32 {
        return Release(&fromSelection(p).base);
    }

    fn isSelected(self: *const SettingsSectionProvider) bool {
        return !self.container.detached.load(.acquire) and
            self.container.selected_index.load(.acquire) == self.index;
    }

    fn Select(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (IsWindowEnabled(self.hwnd) == 0) return com.UIA_E_ELEMENTNOTENABLED;
        const result = sendButtonClicked(self.hwnd);
        if (result != com.S_OK) return result;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return if (self.isSelected()) com.S_OK else com.UIA_E_INVALIDOPERATION;
    }

    fn AddToSelection(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return settingsSectionAddToSelectionResult(self.isSelected());
    }

    fn RemoveFromSelection(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return settingsSectionRemoveFromSelectionResult(self.isSelected());
    }

    fn GetIsSelected(
        p: *com.ISelectionItemProvider,
        out: *com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = if (self.isSelected()) 1 else 0;
        return com.S_OK;
    }

    fn GetSelectionContainer(
        p: *com.ISelectionItemProvider,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.container.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = &self.container.base;
        _ = SettingsSectionGroupProvider.AddRef(&self.container.base);
        return com.S_OK;
    }
};

fn settingsSectionAddToSelectionResult(selected: bool) com.HRESULT {
    return if (selected) com.S_OK else com.UIA_E_INVALIDOPERATION;
}

fn settingsSectionRemoveFromSelectionResult(selected: bool) com.HRESULT {
    return if (selected) com.UIA_E_INVALIDOPERATION else com.S_OK;
}

pub fn returnSettingsSectionProvider(
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    provider: *SettingsSectionProvider,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;
    if (!provider.available() or provider.hwnd != hwnd) return null;
    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

pub const ChromeControlState = struct {
    pub const Role = enum {
        tab_container,
        tab_item,
        button,
        toggle,
        live_text,
        scrollbar,
        decorative,
    };

    ctx: *anyopaque,
    role: Role,
    tag: usize = 0,
    name: *const fn (*anyopaque, usize, []u8) []const u8,
    selected: ?*const fn (*anyopaque, usize) bool = null,
    selected_provider: ?*const fn (*anyopaque) ?*ChromeControlProvider = null,
    selection_container: ?*const fn (*anyopaque) ?*ChromeControlProvider = null,
    toggled: ?*const fn (*anyopaque, usize) bool = null,
    range_value: ?*const fn (*anyopaque) ChromeRangeValue = null,
    use_com_threading: bool = false,
};

pub const ChromeRangeValue = struct {
    value: f64,
    minimum: f64,
    maximum: f64,
    large_change: f64,
    small_change: f64,
};

/// Concrete provider for native host-chrome HWNDs. The role is fixed at
/// creation; live names, selection, toggles, and scrollbar values are queried
/// from their owner only while the provider remains attached.
pub const ChromeControlProvider = struct {
    base: com.IRawElementProviderSimple,
    invoke_iface: com.IInvokeProvider,
    toggle_iface: com.IToggleProvider,
    range_iface: com.IRangeValueProvider,
    selection_iface: com.ISelectionProvider,
    selection_item_iface: com.ISelectionItemProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state: ChromeControlState,
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),

    const simple_vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .get_ProviderOptions = get_ProviderOptions,
        .GetPatternProvider = GetPatternProvider,
        .GetPropertyValue = GetPropertyValue,
        .get_HostRawElementProvider = get_HostRawElementProvider,
    };
    const invoke_vtbl: com.IInvokeProviderVtbl = .{
        .QueryInterface = InvokeQueryInterface,
        .AddRef = InvokeAddRef,
        .Release = InvokeRelease,
        .Invoke = Invoke,
    };
    const toggle_vtbl: com.IToggleProviderVtbl = .{
        .QueryInterface = ToggleQueryInterface,
        .AddRef = ToggleAddRef,
        .Release = ToggleRelease,
        .Toggle = Toggle,
        .get_ToggleState = GetToggleState,
    };
    const range_vtbl: com.IRangeValueProviderVtbl = .{
        .QueryInterface = RangeQueryInterface,
        .AddRef = RangeAddRef,
        .Release = RangeRelease,
        .SetValue = SetRangeValue,
        .get_Value = GetRangeValue,
        .get_IsReadOnly = GetRangeIsReadOnly,
        .get_Maximum = GetRangeMaximum,
        .get_Minimum = GetRangeMinimum,
        .get_LargeChange = GetRangeLargeChange,
        .get_SmallChange = GetRangeSmallChange,
    };
    const selection_vtbl: com.ISelectionProviderVtbl = .{
        .QueryInterface = SelectionQueryInterface,
        .AddRef = SelectionAddRef,
        .Release = SelectionRelease,
        .GetSelection = GetSelection,
        .get_CanSelectMultiple = GetCanSelectMultiple,
        .get_IsSelectionRequired = GetIsSelectionRequired,
    };
    const selection_item_vtbl: com.ISelectionItemProviderVtbl = .{
        .QueryInterface = SelectionItemQueryInterface,
        .AddRef = SelectionItemAddRef,
        .Release = SelectionItemRelease,
        .Select = Select,
        .AddToSelection = AddToSelection,
        .RemoveFromSelection = RemoveFromSelection,
        .get_IsSelected = GetIsSelected,
        .get_SelectionContainer = GetSelectionContainer,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        state: ChromeControlState,
    ) !*ChromeControlProvider {
        const self = try alloc.create(ChromeControlProvider);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .invoke_iface = .{ .vtbl = &invoke_vtbl },
            .toggle_iface = .{ .vtbl = &toggle_vtbl },
            .range_iface = .{ .vtbl = &range_vtbl },
            .selection_iface = .{ .vtbl = &selection_vtbl },
            .selection_item_iface = .{ .vtbl = &selection_item_vtbl },
            .refcount = .init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .state = state,
            .detached = .init(false),
            .disconnected = .init(false),
        };
        return self;
    }

    pub fn detach(self: *ChromeControlProvider) void {
        self.detached.store(true, .release);
    }

    pub fn disconnect(self: *ChromeControlProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        return self.finishDisconnect(com.UiaDisconnectProvider(&self.base));
    }

    /// Latch the terminal disconnect flag only once UIA has actually released
    /// the provider. `RPC_E_CANTCALLOUT_ININPUTSYNCCALL` is transient and the
    /// deferred-disconnect pass retries it; latching on failure would turn
    /// that retry into a silent `S_OK` that drops the creation reference while
    /// the provider is still registered for an HWND that is already gone.
    fn finishDisconnect(self: *ChromeControlProvider, hr: com.HRESULT) com.HRESULT {
        if (hr == com.S_OK) self.disconnected.store(true, .release);
        return hr;
    }

    pub fn raiseNameChanged(self: *ChromeControlProvider) void {
        if (!self.available()) return;
        events.raiseNameChanged(&self.base);
    }

    pub fn raiseSelected(self: *ChromeControlProvider, old: bool, new: bool) void {
        if (!self.available() or old == new) return;
        events.raisePropertyChanged(
            &self.base,
            constants.UIA_SelectionItemIsSelectedPropertyId,
            com.VARIANT.fromBool(old),
            com.VARIANT.fromBool(new),
        );
        if (new) events.raiseSelectionItemSelected(&self.base);
    }

    pub fn raiseToggleChanged(self: *ChromeControlProvider, old: bool, new: bool) void {
        if (!self.available() or old == new) return;
        events.raisePropertyChanged(
            &self.base,
            constants.UIA_ToggleToggleStatePropertyId,
            com.VARIANT.fromI4(if (old) 1 else 0),
            com.VARIANT.fromI4(if (new) 1 else 0),
        );
    }

    fn raiseRangePropertyChanged(
        self: *ChromeControlProvider,
        property_id: i32,
        old: f64,
        new: f64,
    ) void {
        if (!self.available() or old == new) return;
        events.raisePropertyChanged(
            &self.base,
            property_id,
            com.VARIANT.fromR8(old),
            com.VARIANT.fromR8(new),
        );
    }

    pub fn raiseRangeChanged(
        self: *ChromeControlProvider,
        old: ChromeRangeValue,
        new: ChromeRangeValue,
    ) void {
        self.raiseRangePropertyChanged(constants.UIA_RangeValueValuePropertyId, old.value, new.value);
        self.raiseRangePropertyChanged(constants.UIA_RangeValueMinimumPropertyId, old.minimum, new.minimum);
        self.raiseRangePropertyChanged(constants.UIA_RangeValueMaximumPropertyId, old.maximum, new.maximum);
        self.raiseRangePropertyChanged(constants.UIA_RangeValueLargeChangePropertyId, old.large_change, new.large_change);
        self.raiseRangePropertyChanged(constants.UIA_RangeValueSmallChangePropertyId, old.small_change, new.small_change);
    }

    pub fn raiseLiveRegionChanged(self: *ChromeControlProvider) void {
        if (!self.available()) return;
        events.raiseNameChanged(&self.base);
        events.raiseLiveRegionChanged(&self.base);
    }

    pub fn raiseFocusChanged(self: *ChromeControlProvider) void {
        if (!self.available()) return;
        events.raiseFocusChanged(&self.base);
    }

    fn available(self: *const ChromeControlProvider) bool {
        return !self.detached.load(.acquire) and IsWindow(self.hwnd) != 0;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *ChromeControlProvider {
        return @fieldParentPtr("base", p);
    }
    fn fromInvoke(p: *com.IInvokeProvider) *ChromeControlProvider {
        return @fieldParentPtr("invoke_iface", p);
    }
    fn fromToggle(p: *com.IToggleProvider) *ChromeControlProvider {
        return @fieldParentPtr("toggle_iface", p);
    }
    fn fromRange(p: *com.IRangeValueProvider) *ChromeControlProvider {
        return @fieldParentPtr("range_iface", p);
    }
    fn fromSelection(p: *com.ISelectionProvider) *ChromeControlProvider {
        return @fieldParentPtr("selection_iface", p);
    }
    fn fromSelectionItem(p: *com.ISelectionItemProvider) *ChromeControlProvider {
        return @fieldParentPtr("selection_item_iface", p);
    }

    fn QueryInterface(
        self_base: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or iidEqual(iid, &com.IID_IRawElementProviderSimple)) {
            out.* = @ptrCast(&self.base);
        } else if ((self.state.role == .button) and iidEqual(iid, &com.IID_IInvokeProvider)) {
            out.* = @ptrCast(&self.invoke_iface);
        } else if (self.state.role == .toggle and iidEqual(iid, &com.IID_IToggleProvider)) {
            out.* = @ptrCast(&self.toggle_iface);
        } else if (self.state.role == .scrollbar and iidEqual(iid, &com.IID_IRangeValueProvider)) {
            out.* = @ptrCast(&self.range_iface);
        } else if (self.state.role == .tab_container and iidEqual(iid, &com.IID_ISelectionProvider)) {
            out.* = @ptrCast(&self.selection_iface);
        } else if (self.state.role == .tab_item and iidEqual(iid, &com.IID_ISelectionItemProvider)) {
            out.* = @ptrCast(&self.selection_item_iface);
        } else return com.E_NOINTERFACE;
        _ = AddRef(&self.base);
        return com.S_OK;
    }

    pub fn AddRef(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(self_base).refcount.fetchAdd(1, .monotonic) + 1;
    }

    pub fn Release(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }

    fn get_ProviderOptions(
        self_base: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = com.ProviderOptions_ServerSideProvider |
            (if (self.state.use_com_threading) com.ProviderOptions_UseComThreading else 0);
        return com.S_OK;
    }

    fn GetPatternProvider(
        self_base: *com.IRawElementProviderSimple,
        pattern_id: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const pattern: ?*com.IUnknown = switch (self.state.role) {
            .button => if (pattern_id == constants.UIA_InvokePatternId) @ptrCast(&self.invoke_iface) else null,
            .toggle => if (pattern_id == constants.UIA_TogglePatternId) @ptrCast(&self.toggle_iface) else null,
            .scrollbar => if (pattern_id == constants.UIA_RangeValuePatternId) @ptrCast(&self.range_iface) else null,
            .tab_container => if (pattern_id == constants.UIA_SelectionPatternId) @ptrCast(&self.selection_iface) else null,
            .tab_item => if (pattern_id == constants.UIA_SelectionItemPatternId) @ptrCast(&self.selection_item_iface) else null,
            .live_text, .decorative => null,
        };
        out.* = pattern orelse return com.S_OK;
        _ = AddRef(&self.base);
        return com.S_OK;
    }

    fn GetPropertyValue(
        self_base: *com.IRawElementProviderSimple,
        property_id: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = com.VARIANT.empty();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        switch (property_id) {
            constants.UIA_ControlTypePropertyId => out.* = com.VARIANT.fromI4(switch (self.state.role) {
                .tab_container => constants.UIA_TabControlTypeId,
                .tab_item => constants.UIA_TabItemControlTypeId,
                .button, .toggle => constants.UIA_ButtonControlTypeId,
                .live_text, .decorative => constants.UIA_TextControlTypeId,
                .scrollbar => constants.UIA_ScrollBarControlTypeId,
            }),
            constants.UIA_NamePropertyId => {
                var buf: [512]u8 = undefined;
                const name = self.state.name(self.state.ctx, self.state.tag, &buf);
                const value = allocBstrFromUtf8(self.alloc, name) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(value);
            },
            constants.UIA_FrameworkIdPropertyId => {
                out.* = com.VARIANT.fromBstr(com.SysAllocString(
                    std.unicode.utf8ToUtf16LeStringLiteral("Win32"),
                ) orelse return com.E_OUTOFMEMORY);
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            => out.* = com.VARIANT.fromBool(self.state.role != .decorative),
            constants.UIA_IsEnabledPropertyId => out.* = com.VARIANT.fromBool(IsWindowEnabled(self.hwnd) != 0),
            constants.UIA_IsOffscreenPropertyId => out.* = com.VARIANT.fromBool(IsWindowVisible(self.hwnd) == 0),
            constants.UIA_IsKeyboardFocusablePropertyId => out.* = com.VARIANT.fromBool(switch (self.state.role) {
                .tab_item, .button, .toggle => true,
                else => false,
            }),
            constants.UIA_HasKeyboardFocusPropertyId => out.* = com.VARIANT.fromBool(hwndHasKeyboardFocus(self.hwnd)),
            constants.UIA_SelectionItemIsSelectedPropertyId => if (self.state.role == .tab_item) {
                const selected = self.state.selected orelse return com.E_NOTIMPL;
                out.* = com.VARIANT.fromBool(selected(self.state.ctx, self.state.tag));
            },
            constants.UIA_ToggleToggleStatePropertyId => if (self.state.role == .toggle) {
                const toggled = self.state.toggled orelse return com.E_NOTIMPL;
                out.* = com.VARIANT.fromI4(if (toggled(self.state.ctx, self.state.tag)) 1 else 0);
            },
            constants.UIA_LiveSettingPropertyId => if (self.state.role == .live_text) {
                out.* = com.VARIANT.fromI4(constants.LiveSetting_Polite);
            },
            constants.UIA_RangeValueValuePropertyId,
            constants.UIA_RangeValueMinimumPropertyId,
            constants.UIA_RangeValueMaximumPropertyId,
            constants.UIA_RangeValueLargeChangePropertyId,
            constants.UIA_RangeValueSmallChangePropertyId,
            constants.UIA_RangeValueIsReadOnlyPropertyId,
            => if (self.state.role == .scrollbar) {
                const current_range = (self.state.range_value orelse return com.E_NOTIMPL)(self.state.ctx);
                out.* = switch (property_id) {
                    constants.UIA_RangeValueValuePropertyId => com.VARIANT.fromR8(current_range.value),
                    constants.UIA_RangeValueMinimumPropertyId => com.VARIANT.fromR8(current_range.minimum),
                    constants.UIA_RangeValueMaximumPropertyId => com.VARIANT.fromR8(current_range.maximum),
                    constants.UIA_RangeValueLargeChangePropertyId => com.VARIANT.fromR8(current_range.large_change),
                    constants.UIA_RangeValueSmallChangePropertyId => com.VARIANT.fromR8(current_range.small_change),
                    else => com.VARIANT.fromBool(true),
                };
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
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }

    fn InvokeQueryInterface(p: *com.IInvokeProvider, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromInvoke(p).base, iid, out);
    }
    fn InvokeAddRef(p: *com.IInvokeProvider) callconv(.winapi) u32 {
        return AddRef(&fromInvoke(p).base);
    }
    fn InvokeRelease(p: *com.IInvokeProvider) callconv(.winapi) u32 {
        return Release(&fromInvoke(p).base);
    }
    fn Invoke(p: *com.IInvokeProvider) callconv(.winapi) com.HRESULT {
        const self = fromInvoke(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.state.role != .button) return com.UIA_E_INVALIDOPERATION;
        return postButtonClicked(self.hwnd);
    }

    fn ToggleQueryInterface(p: *com.IToggleProvider, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromToggle(p).base, iid, out);
    }
    fn ToggleAddRef(p: *com.IToggleProvider) callconv(.winapi) u32 {
        return AddRef(&fromToggle(p).base);
    }
    fn ToggleRelease(p: *com.IToggleProvider) callconv(.winapi) u32 {
        return Release(&fromToggle(p).base);
    }
    fn Toggle(p: *com.IToggleProvider) callconv(.winapi) com.HRESULT {
        const self = fromToggle(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.state.role != .toggle) return com.UIA_E_INVALIDOPERATION;
        return sendButtonClicked(self.hwnd);
    }
    fn GetToggleState(p: *com.IToggleProvider, out: *i32) callconv(.winapi) com.HRESULT {
        const self = fromToggle(p);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const toggled = self.state.toggled orelse return com.E_NOTIMPL;
        out.* = if (toggled(self.state.ctx, self.state.tag)) 1 else 0;
        return com.S_OK;
    }

    fn RangeQueryInterface(p: *com.IRangeValueProvider, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromRange(p).base, iid, out);
    }
    fn RangeAddRef(p: *com.IRangeValueProvider) callconv(.winapi) u32 {
        return AddRef(&fromRange(p).base);
    }
    fn RangeRelease(p: *com.IRangeValueProvider) callconv(.winapi) u32 {
        return Release(&fromRange(p).base);
    }
    fn range(self: *ChromeControlProvider) ?ChromeRangeValue {
        if (!self.available() or self.state.role != .scrollbar) return null;
        return (self.state.range_value orelse return null)(self.state.ctx);
    }
    fn SetRangeValue(p: *com.IRangeValueProvider, _: f64) callconv(.winapi) com.HRESULT {
        const self = fromRange(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.UIA_E_INVALIDOPERATION;
    }
    fn GetRangeValue(p: *com.IRangeValueProvider, out: *f64) callconv(.winapi) com.HRESULT {
        out.* = 0;
        const value = fromRange(p).range() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = value.value;
        return com.S_OK;
    }
    fn GetRangeIsReadOnly(p: *com.IRangeValueProvider, out: *com.BOOL) callconv(.winapi) com.HRESULT {
        out.* = 0;
        _ = fromRange(p).range() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = 1;
        return com.S_OK;
    }
    fn GetRangeMaximum(p: *com.IRangeValueProvider, out: *f64) callconv(.winapi) com.HRESULT {
        out.* = 0;
        const value = fromRange(p).range() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = value.maximum;
        return com.S_OK;
    }
    fn GetRangeMinimum(p: *com.IRangeValueProvider, out: *f64) callconv(.winapi) com.HRESULT {
        out.* = 0;
        const value = fromRange(p).range() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = value.minimum;
        return com.S_OK;
    }
    fn GetRangeLargeChange(p: *com.IRangeValueProvider, out: *f64) callconv(.winapi) com.HRESULT {
        out.* = 0;
        const value = fromRange(p).range() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = value.large_change;
        return com.S_OK;
    }
    fn GetRangeSmallChange(p: *com.IRangeValueProvider, out: *f64) callconv(.winapi) com.HRESULT {
        out.* = 0;
        const value = fromRange(p).range() orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = value.small_change;
        return com.S_OK;
    }

    fn SelectionQueryInterface(p: *com.ISelectionProvider, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromSelection(p).base, iid, out);
    }
    fn SelectionAddRef(p: *com.ISelectionProvider) callconv(.winapi) u32 {
        return AddRef(&fromSelection(p).base);
    }
    fn SelectionRelease(p: *com.ISelectionProvider) callconv(.winapi) u32 {
        return Release(&fromSelection(p).base);
    }
    fn GetSelection(p: *com.ISelectionProvider, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        const self = fromSelection(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const selected = (self.state.selected_provider orelse return com.E_NOTIMPL)(self.state.ctx) orelse {
            out.* = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, 0) orelse return com.E_OUTOFMEMORY;
            return com.S_OK;
        };
        if (!selected.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const array = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, 1) orelse return com.E_OUTOFMEMORY;
        var index: i32 = 0;
        const hr = com.SafeArrayPutElement(array, &index, @ptrCast(&selected.base));
        if (hr != com.S_OK) {
            _ = com.SafeArrayDestroy(array);
            return hr;
        }
        out.* = array;
        return com.S_OK;
    }
    fn GetCanSelectMultiple(p: *com.ISelectionProvider, out: *com.BOOL) callconv(.winapi) com.HRESULT {
        out.* = 0;
        if (!fromSelection(p).available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.S_OK;
    }
    fn GetIsSelectionRequired(p: *com.ISelectionProvider, out: *com.BOOL) callconv(.winapi) com.HRESULT {
        out.* = 0;
        if (!fromSelection(p).available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = 1;
        return com.S_OK;
    }

    fn SelectionItemQueryInterface(p: *com.ISelectionItemProvider, iid: *const com.GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT {
        return QueryInterface(&fromSelectionItem(p).base, iid, out);
    }
    fn SelectionItemAddRef(p: *com.ISelectionItemProvider) callconv(.winapi) u32 {
        return AddRef(&fromSelectionItem(p).base);
    }
    fn SelectionItemRelease(p: *com.ISelectionItemProvider) callconv(.winapi) u32 {
        return Release(&fromSelectionItem(p).base);
    }
    fn Select(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        const self = fromSelectionItem(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const result = sendButtonClicked(self.hwnd);
        if (result != com.S_OK) return result;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const selected = self.state.selected orelse return com.E_NOTIMPL;
        return if (selected(self.state.ctx, self.state.tag)) com.S_OK else com.UIA_E_INVALIDOPERATION;
    }
    /// The tab container reports `CanSelectMultiple = false`, so UIA defines
    /// `AddToSelection` on an item that is not already selected as an invalid
    /// operation rather than a silent tab switch. `Select` remains the
    /// documented way to move the selection.
    fn AddToSelection(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        const self = fromSelectionItem(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const selected = self.state.selected orelse return com.E_NOTIMPL;
        return if (selected(self.state.ctx, self.state.tag)) com.S_OK else com.UIA_E_INVALIDOPERATION;
    }
    fn RemoveFromSelection(p: *com.ISelectionItemProvider) callconv(.winapi) com.HRESULT {
        const self = fromSelectionItem(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const selected = self.state.selected orelse return com.E_NOTIMPL;
        return if (selected(self.state.ctx, self.state.tag)) com.UIA_E_INVALIDOPERATION else com.S_OK;
    }
    fn GetIsSelected(p: *com.ISelectionItemProvider, out: *com.BOOL) callconv(.winapi) com.HRESULT {
        const self = fromSelectionItem(p);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const selected = self.state.selected orelse return com.E_NOTIMPL;
        out.* = if (selected(self.state.ctx, self.state.tag)) 1 else 0;
        return com.S_OK;
    }
    fn GetSelectionContainer(
        p: *com.ISelectionItemProvider,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromSelectionItem(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const container = (self.state.selection_container orelse return com.E_NOTIMPL)(self.state.ctx) orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!container.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        _ = AddRef(&container.base);
        out.* = &container.base;
        return com.S_OK;
    }
};

pub fn returnChromeControlProvider(
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    provider: *ChromeControlProvider,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId or !provider.available() or provider.hwnd != hwnd) return null;
    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

pub const TerminalProvider = struct {
    base: com.IRawElementProviderSimple,
    value_iface: com.IValueProvider,
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

    const value_vtbl: com.IValueProviderVtbl = .{
        .QueryInterface = TerminalProvider.ValueQueryInterface,
        .AddRef = TerminalProvider.ValueAddRef,
        .Release = TerminalProvider.ValueRelease,
        .SetValue = TerminalProvider.SetValue,
        .get_Value = TerminalProvider.GetValue,
        .get_IsReadOnly = TerminalProvider.GetIsReadOnly,
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
            .value_iface = .{ .vtbl = &value_vtbl },
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

    fn fromValue(p: *com.IValueProvider) *TerminalProvider {
        return @fieldParentPtr("value_iface", p);
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

    fn ValueQueryInterface(
        self_value: *com.IValueProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromValue(self_value).queryInterface(iid, out);
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
        if (self.state.role == .edit and iidEqual(iid, &com.IID_IValueProvider)) {
            out.* = @ptrCast(&self.value_iface);
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

    fn ValueAddRef(self_value: *com.IValueProvider) callconv(.winapi) u32 {
        return fromValue(self_value).refcount.fetchAdd(1, .monotonic) + 1;
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

    fn ValueRelease(self_value: *com.IValueProvider) callconv(.winapi) u32 {
        return fromValue(self_value).release();
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
        self_base: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = com.ProviderOptions_ServerSideProvider |
            (if (self.state.use_com_threading) com.ProviderOptions_UseComThreading else 0);
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
        } else if (pattern_id == constants.UIA_ValuePatternId and self.state.role == .edit) {
            out.* = @ptrCast(&self.value_iface);
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
                out.* = com.VARIANT.fromI4(switch (self.state.role) {
                    .terminal => constants.UIA_TextControlTypeId,
                    .edit => constants.UIA_EditControlTypeId,
                });
            },
            constants.UIA_NamePropertyId => {
                var buf: [256]u8 = undefined;
                const name = self.state.name(self.state.ctx, &buf);
                const bstr = allocBstrFromUtf8(self.alloc, name) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_LocalizedControlTypePropertyId => {
                const literal = switch (self.state.role) {
                    .terminal => std.unicode.utf8ToUtf16LeStringLiteral("terminal"),
                    .edit => std.unicode.utf8ToUtf16LeStringLiteral("edit"),
                };
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_HelpTextPropertyId => {
                const literal = switch (self.state.role) {
                    .terminal => std.unicode.utf8ToUtf16LeStringLiteral("Read-only terminal text"),
                    .edit => if (self.state.set_value == null)
                        std.unicode.utf8ToUtf16LeStringLiteral("Read-only text")
                    else
                        std.unicode.utf8ToUtf16LeStringLiteral("Editable text"),
                };
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_ValueValuePropertyId => if (self.state.role == .edit) {
                const bstr = self.allocCurrentValueBstr() orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_ValueIsReadOnlyPropertyId => if (self.state.role == .edit) {
                out.* = com.VARIANT.fromBool(self.state.set_value == null);
            },
            constants.UIA_LiveSettingPropertyId => if (self.state.role == .terminal) {
                out.* = com.VARIANT.fromI4(constants.LiveSetting_Polite);
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            constants.UIA_IsEnabledPropertyId,
            constants.UIA_IsKeyboardFocusablePropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_HasKeyboardFocusPropertyId => {
                out.* = com.VARIANT.fromBool(self.state.focused(self.state.ctx));
            },
            constants.UIA_IsOffscreenPropertyId => {
                out.* = com.VARIANT.fromBool(windowVisibilityIsOffscreen(IsWindowVisible(self.hwnd)));
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

    fn allocCurrentValueBstr(self: *TerminalProvider) com.BSTR {
        const value = self.state.value(self.state.ctx, self.alloc) catch return null;
        defer self.alloc.free(value);
        return allocBstrFromUtf8(self.alloc, value);
    }

    fn SetValue(
        self_value: *com.IValueProvider,
        value_w: [*:0]const u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(self_value);
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.state.role != .edit) return com.UIA_E_INVALIDOPERATION;
        const set_value = self.state.set_value orelse return com.UIA_E_INVALIDOPERATION;
        const value_len = std.mem.len(value_w);
        const value = std.unicode.utf16LeToUtf8Alloc(self.alloc, value_w[0..value_len]) catch |err| {
            return if (err == error.OutOfMemory) com.E_OUTOFMEMORY else com.E_INVALIDARG;
        };
        defer self.alloc.free(value);
        set_value(self.state.ctx, value) catch |err| {
            return if (err == error.OutOfMemory) com.E_OUTOFMEMORY else com.E_INVALIDARG;
        };
        return com.S_OK;
    }

    fn GetValue(
        self_value: *com.IValueProvider,
        out: *com.BSTR,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(self_value);
        out.* = null;
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.state.role != .edit) return com.UIA_E_INVALIDOPERATION;
        out.* = self.allocCurrentValueBstr() orelse return com.E_OUTOFMEMORY;
        return com.S_OK;
    }

    fn GetIsReadOnly(
        self_value: *com.IValueProvider,
        out: *com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(self_value);
        out.* = 0;
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.state.role != .edit) return com.UIA_E_INVALIDOPERATION;
        out.* = if (self.state.set_value == null) 1 else 0;
        return com.S_OK;
    }

    fn GetSelection(
        self_text: *com.ITextProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        const self = fromText(self_text);
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        var snapshot = self.terminalSnapshot() catch |err| return switch (err) {
            error.ElementNotAvailable => com.UIA_E_ELEMENTNOTAVAILABLE,
            else => com.E_OUTOFMEMORY,
        };
        defer self.alloc.free(snapshot.visible_text);
        // ITextProvider::GetSelection is documented to return a degenerate
        // range at the insertion point when a control has a caret but no
        // selection; an empty array is only correct for a control with no
        // insertion point at all. A terminal always has a caret, so clients
        // that track it through GetSelection rather than TextPattern2's
        // GetCaretRange keep working. The caret anchor matches GetCaretRange:
        // the active end of a live selection, otherwise the cursor.
        const selection_range = if (self.state.role == .terminal)
            snapshot.terminal_selection_range orelse terminal_text.OffsetRange{
                .start = snapshot.caret_offset,
                .end = snapshot.caret_offset,
            }
        else
            snapshot.selection_range;
        var range: ?*com.ITextRangeProvider = null;
        const range_hr = self.createRangeFromSnapshot(&snapshot, selection_range, &range);
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
        const self = fromText(self_text);
        out.* = com.SupportedTextSelection_None;
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.state.role == .edit) {
            out.* = com.SupportedTextSelection_Single;
        }
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

        const caret_offset = if (self.state.role == .terminal)
            terminal_snapshot.terminal_selection_active_offset orelse terminal_snapshot.caret_offset
        else
            terminal_snapshot.caret_offset;
        const hr = self.createRangeFromSnapshot(
            &terminal_snapshot,
            .{
                .start = caret_offset,
                .end = caret_offset,
            },
            out,
        );
        if (hr == com.S_OK) {
            is_active.* = if (self.state.focused(self.state.ctx)) 1 else 0;
        }
        return hr;
    }

    /// UI-thread event hook used after the owning terminal publishes a new
    /// immutable snapshot.
    pub fn raiseTextChanged(self: *TerminalProvider) void {
        if (self.detached.load(.acquire)) return;
        events.raiseTextChanged(&self.base);
    }

    pub fn raiseTextSelectionChanged(self: *TerminalProvider) void {
        if (self.detached.load(.acquire)) return;
        events.raiseTextSelectionChanged(&self.base);
    }

    pub fn raiseValueChanged(self: *TerminalProvider) void {
        if (self.detached.load(.acquire) or self.state.role != .edit) return;
        events.raiseCurrentStringPropertyChanged(&self.base, constants.UIA_ValueValuePropertyId);
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

    fn terminalSnapshot(self: *TerminalProvider) !TerminalSnapshot {
        if (self.detached.load(.acquire)) return error.ElementNotAvailable;
        var raw_snapshot = if (self.state.snapshot) |snapshot_fn| snapshot: {
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

        const raw_start = @min(raw_snapshot.visible_range.start, raw_snapshot.document_text.len);
        const raw_end = @min(@max(raw_start, raw_snapshot.visible_range.end), raw_snapshot.document_text.len);
        const visible_start = utf8BoundaryAtOrBefore(raw_snapshot.document_text, raw_start);
        const visible_end = utf8BoundaryAtOrBefore(raw_snapshot.document_text, raw_end);
        if (visible_start != raw_start or visible_end != raw_end) {
            const normalized_visible_text = try self.alloc.dupe(
                u8,
                raw_snapshot.document_text[visible_start..visible_end],
            );
            self.alloc.free(raw_snapshot.visible_text);
            raw_snapshot.visible_text = normalized_visible_text;
        }
        const caret_offset = utf8BoundaryAtOrBefore(
            raw_snapshot.document_text,
            @min(raw_snapshot.caret_offset, raw_snapshot.document_text.len),
        );
        const selection_start = utf8BoundaryAtOrBefore(
            raw_snapshot.document_text,
            @min(raw_snapshot.selection_range.start, raw_snapshot.document_text.len),
        );
        const selection_end = utf8BoundaryAtOrBefore(
            raw_snapshot.document_text,
            @min(raw_snapshot.selection_range.end, raw_snapshot.document_text.len),
        );
        const terminal_selection_range = if (raw_snapshot.terminal_selection_range) |selection| blk: {
            const start = utf8BoundaryAtOrBefore(
                raw_snapshot.document_text,
                @min(selection.start, raw_snapshot.document_text.len),
            );
            const end = utf8BoundaryAtOrBefore(
                raw_snapshot.document_text,
                @min(selection.end, raw_snapshot.document_text.len),
            );
            break :blk terminal_text.OffsetRange{
                .start = @min(start, end),
                .end = @max(start, end),
            };
        } else null;
        const terminal_selection_active_offset = if (raw_snapshot.terminal_selection_active_offset) |active|
            utf8BoundaryAtOrBefore(
                raw_snapshot.document_text,
                @min(active, raw_snapshot.document_text.len),
            )
        else
            null;
        return .{
            .document_text = raw_snapshot.document_text,
            .visible_text = raw_snapshot.visible_text,
            .visible_range = .{ .start = visible_start, .end = visible_end },
            .caret_offset = caret_offset,
            .selection_range = .{
                .start = @min(selection_start, selection_end),
                .end = @max(selection_start, selection_end),
            },
            .terminal_selection_range = terminal_selection_range,
            .terminal_selection_active_offset = terminal_selection_active_offset,
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
        const self = fromBase(self_base);
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        // A terminal owns its PTY caret and cannot persist an arbitrary UIA
        // selection. Keep GetSelection useful for caret review, but report
        // mutation as unsupported rather than acknowledging a no-op.
        if (self.parent.state.role == .terminal) return com.UIA_E_INVALIDOPERATION;
        const select_range = self.parent.state.select_range orelse return com.E_NOTIMPL;
        select_range(self.parent.state.ctx, self.text, self.range) catch |err| {
            return if (err == error.OutOfMemory) com.E_OUTOFMEMORY else com.UIA_E_INVALIDOPERATION;
        };
        return com.S_OK;
    }

    fn AddToSelection(self_base: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.UIA_E_INVALIDOPERATION;
    }

    fn RemoveFromSelection(self_base: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.UIA_E_INVALIDOPERATION;
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

/// Return the stable provider owned by an open quick-select overlay.
pub fn returnQuickSelectProvider(
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    provider: *QuickSelectProvider,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;
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

test "PaletteListProvider exposes configurable identity and focus" {
    var counter: u32 = 0;
    const callbacks = struct {
        fn name(_: *anyopaque, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "Quick select, 1 target", .{}) catch "";
        }

        fn focused(_: *anyopaque) bool {
            return true;
        }
    };
    const state: PaletteListState = .{
        .ctx = @ptrCast(&counter),
        .name = callbacks.name,
        .localized_control_type = "quick select targets",
        .keyboard_focusable = true,
        .focused = callbacks.focused,
    };

    const provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = PaletteListProvider.Release(&provider.base);

    var localized_type = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.GetPropertyValue(
        &provider.base,
        constants.UIA_LocalizedControlTypePropertyId,
        &localized_type,
    ));
    defer _ = com.VariantClear(&localized_type);
    const expected_type = std.unicode.utf8ToUtf16LeStringLiteral("quick select targets");
    try std.testing.expectEqual(@as(u32, expected_type.len), com.SysStringLen(localized_type.value.bstr));
    try std.testing.expectEqualSlices(u16, expected_type, localized_type.value.bstr.?[0..expected_type.len]);

    var focusable = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.GetPropertyValue(
        &provider.base,
        constants.UIA_IsKeyboardFocusablePropertyId,
        &focusable,
    ));
    try std.testing.expectEqual(com.VT_BOOL, focusable.vt);
    try std.testing.expectEqual(com.VARIANT_TRUE, focusable.value.bool_val);

    var focused = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.GetPropertyValue(
        &provider.base,
        constants.UIA_HasKeyboardFocusPropertyId,
        &focused,
    ));
    try std.testing.expectEqual(com.VT_BOOL, focused.vt);
    try std.testing.expectEqual(com.VARIANT_TRUE, focused.value.bool_val);
}

test "palette list and row providers propagate COM threading options" {
    var state_data = TestPaletteState{ .count = 1, .selected = 0 };
    var provider = try PaletteListProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        state_data.state(),
    );
    defer _ = PaletteListProvider.Release(&provider.base);
    const row = provider.createRow(0).?;
    defer _ = PaletteRowProvider.Release(&row.base);

    var list_options: i32 = 0;
    var row_options: i32 = 0;
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.get_ProviderOptions(&provider.base, &list_options));
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.getProviderOptions(&row.base, &row_options));
    try std.testing.expectEqual(com.ProviderOptions_ServerSideProvider, list_options);
    try std.testing.expectEqual(com.ProviderOptions_ServerSideProvider, row_options);

    provider.state.use_com_threading = true;
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.get_ProviderOptions(&provider.base, &list_options));
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.getProviderOptions(&row.base, &row_options));
    const expected = com.ProviderOptions_ServerSideProvider | com.ProviderOptions_UseComThreading;
    try std.testing.expectEqual(expected, list_options);
    try std.testing.expectEqual(expected, row_options);
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
    var bounds = com.UiaRect{ .left = 1, .top = 2, .width = 3, .height = 4 };
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteListProvider.FragmentGetBoundingRectangle(&provider.fragment, &bounds),
    );
    try std.testing.expectEqual(com.UiaRect{ .left = 0, .top = 0, .width = 0, .height = 0 }, bounds);
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
    var bounds = com.UiaRect{ .left = 1, .top = 2, .width = 3, .height = 4 };
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetBoundingRectangle(&row.fragment, &bounds),
    );
    try std.testing.expectEqual(com.UiaRect{ .left = 0, .top = 0, .width = 0, .height = 0 }, bounds);
    var selected: com.BOOL = 1;
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetIsSelected(&row.selection_item, &selected),
    );
    try std.testing.expectEqual(@as(com.BOOL, 0), selected);
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
    bounds = .{ .left = 1, .top = 2, .width = 3, .height = 4 };
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetBoundingRectangle(&row.fragment, &bounds),
    );
    try std.testing.expectEqual(com.UiaRect{ .left = 0, .top = 0, .width = 0, .height = 0 }, bounds);
    selected = 1;
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        PaletteRowProvider.GetIsSelected(&row.selection_item, &selected),
    );
    try std.testing.expectEqual(@as(com.BOOL, 0), selected);
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

test "TerminalProvider TextProvider2 keeps caret outputs safe on range allocation failure" {
    var state_data = TestTerminalStateData{ .caret_offset = 6 };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    const original_alloc = provider.alloc;
    defer provider.alloc = original_alloc;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    provider.alloc = failing.allocator();

    var active: com.BOOL = 1;
    var caret: ?*com.ITextRangeProvider = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.E_OUTOFMEMORY,
        TerminalProvider.GetCaretRange(&provider.text2_iface, &active, &caret),
    );
    try std.testing.expectEqual(@as(com.BOOL, 0), active);
    try std.testing.expect(caret == null);
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

test "TerminalProvider GetSelection reports the caret range and real selections" {
    var state_data = TestTerminalStateData{ .caret_offset = 6 };
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var selection: i32 = -1;
    const hr = TerminalProvider.get_SupportedTextSelection(&p.text_iface, &selection);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(com.SupportedTextSelection_None, selection);

    // No user selection: the documented contract is a degenerate range at
    // the insertion point, not an empty array. The terminal always has one.
    var ranges: ?*com.SAFEARRAY = @ptrFromInt(0x10);
    try std.testing.expectEqual(com.S_OK, TerminalProvider.GetSelection(&p.text_iface, &ranges));
    try std.testing.expect(ranges != null);
    var lower: i32 = -1;
    var upper: i32 = 0;
    try std.testing.expectEqual(com.S_OK, com.SafeArrayGetLBound(ranges.?, 1, &lower));
    try std.testing.expectEqual(com.S_OK, com.SafeArrayGetUBound(ranges.?, 1, &upper));
    try std.testing.expectEqual(@as(i32, 0), lower);
    try std.testing.expectEqual(@as(i32, 0), upper);
    var caret_index: i32 = 0;
    var caret_only: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(ranges.?, &caret_index, @ptrCast(&caret_only)),
    );
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 6, .end = 6 },
        TerminalTextRangeProvider.fromBase(caret_only.?).range,
    );
    _ = TerminalTextRangeProvider.Release(caret_only.?);

    state_data.terminal_selection_range = .{ .start = 2, .end = 7 };
    state_data.terminal_selection_active_offset = 2;
    _ = com.SafeArrayDestroy(ranges);
    ranges = null;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.GetSelection(&p.text_iface, &ranges));
    defer _ = com.SafeArrayDestroy(ranges);
    lower = -1;
    upper = -1;
    try std.testing.expectEqual(com.S_OK, com.SafeArrayGetLBound(ranges.?, 1, &lower));
    try std.testing.expectEqual(com.S_OK, com.SafeArrayGetUBound(ranges.?, 1, &upper));
    try std.testing.expectEqual(@as(i32, 0), lower);
    try std.testing.expectEqual(@as(i32, 0), upper);
    var index: i32 = 0;
    var selected: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(com.S_OK, com.SafeArrayGetElement(ranges.?, &index, @ptrCast(&selected)));
    defer _ = TerminalTextRangeProvider.Release(selected.?);
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 2, .end = 7 },
        TerminalTextRangeProvider.fromBase(selected.?).range,
    );

    var active: com.BOOL = 0;
    var caret: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetCaretRange(&p.text2_iface, &active, &caret),
    );
    defer _ = TerminalTextRangeProvider.Release(caret.?);
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 2, .end = 2 },
        TerminalTextRangeProvider.fromBase(caret.?).range,
    );
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, TerminalTextRangeProvider.Select(selected.?));

    state_data.terminal_selection_active_offset = 7;
    var reverse_caret: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetCaretRange(&p.text2_iface, &active, &reverse_caret),
    );
    defer _ = TerminalTextRangeProvider.Release(reverse_caret.?);
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 7, .end = 7 },
        TerminalTextRangeProvider.fromBase(reverse_caret.?).range,
    );
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
    try std.testing.expectEqual(@as(u32, 1), state_data.snapshot_calls);
}

test "TerminalProvider reports text control type and polite live setting" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var value = com.VARIANT.empty();
    const hr = TerminalProvider.GetPropertyValue(&p.base, constants.UIA_ControlTypePropertyId, &value);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(constants.UIA_TextControlTypeId, value.value.i4);

    value = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPropertyValue(&p.base, constants.UIA_LiveSettingPropertyId, &value),
    );
    try std.testing.expectEqual(constants.LiveSetting_Polite, value.value.i4);
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

test "TerminalProvider retained TextPattern returns fresh immutable document ranges" {
    var state_data = TestTerminalStateData{};
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&state_data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var original_range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.get_DocumentRange(&provider.text_iface, &original_range),
    );
    defer _ = TerminalTextRangeProvider.Release(original_range.?);

    state_data.value_text = "new output";
    state_data.visible_value_text = "new output";
    state_data.visible_range = .{ .start = 0, .end = state_data.value_text.len };
    var refreshed_range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.get_DocumentRange(&provider.text_iface, &refreshed_range),
    );
    defer _ = TerminalTextRangeProvider.Release(refreshed_range.?);

    var original_text: ?[*:0]u16 = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.GetText(original_range.?, -1, &original_text),
    );
    defer com.SysFreeString(original_text);
    try std.testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("hello\nworld"),
        original_text.?[0..11],
    );

    var refreshed_text: ?[*:0]u16 = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalTextRangeProvider.GetText(refreshed_range.?, -1, &refreshed_text),
    );
    defer com.SysFreeString(refreshed_text);
    try std.testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("new output"),
        refreshed_text.?[0..10],
    );
    try std.testing.expectEqual(@as(u32, 2), state_data.value_calls);
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
    try std.testing.expectEqual(@as(u32, 1), state_data.snapshot_calls);
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

    var pattern: ?*com.IUnknown = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&p.base, constants.UIA_ValuePatternId, &pattern),
    );
    try std.testing.expect(pattern == null);

    var iface: ?*anyopaque = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.E_NOINTERFACE,
        TerminalProvider.QueryInterface(&p.base, &com.IID_IValueProvider, &iface),
    );
    try std.testing.expect(iface == null);
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
    snapshot_calls: u32 = 0,
    retains: u32 = 0,
    releases: u32 = 0,
    value_text: []const u8 = "hello\nworld",
    visible_value_text: []const u8 = "visible",
    visible_range: terminal_text.OffsetRange = .{ .start = 0, .end = 7 },
    caret_offset: usize = 0,
    terminal_selection_range: ?terminal_text.OffsetRange = null,
    terminal_selection_active_offset: ?usize = null,
};

const TestEditStateData = struct {
    value_buf: [64]u8 = undefined,
    value_len: usize = 0,
    selection_range: terminal_text.OffsetRange = .{ .start = 0, .end = 0 },
    set_value_calls: u32 = 0,
    select_calls: u32 = 0,
    selected_range: terminal_text.OffsetRange = .{ .start = 0, .end = 0 },

    fn assign(self: *TestEditStateData, new_value: []const u8) void {
        std.debug.assert(new_value.len <= self.value_buf.len);
        @memcpy(self.value_buf[0..new_value.len], new_value);
        self.value_len = new_value.len;
    }

    fn value(self: *const TestEditStateData) []const u8 {
        return self.value_buf[0..self.value_len];
    }

    fn state(self: *TestEditStateData) TerminalState {
        const callbacks = struct {
            fn name(_: *anyopaque, _: []u8) []const u8 {
                return "Search query";
            }

            fn value(ctx: *anyopaque, alloc: std.mem.Allocator) ![]u8 {
                const data: *TestEditStateData = @ptrCast(@alignCast(ctx));
                return alloc.dupe(u8, data.value());
            }

            fn snapshot(ctx: *anyopaque, alloc: std.mem.Allocator) !TerminalSnapshot {
                const data: *TestEditStateData = @ptrCast(@alignCast(ctx));
                const document_text = try alloc.dupe(u8, data.value());
                errdefer alloc.free(document_text);
                return .{
                    .document_text = document_text,
                    .visible_text = try alloc.dupe(u8, data.value()),
                    .visible_range = .{ .start = 0, .end = data.value_len },
                    .caret_offset = data.selection_range.end,
                    .selection_range = data.selection_range,
                };
            }

            fn focused(_: *anyopaque) bool {
                return true;
            }

            fn setValue(ctx: *anyopaque, new_value: []const u8) !void {
                const data: *TestEditStateData = @ptrCast(@alignCast(ctx));
                if (new_value.len > data.value_buf.len) return error.ValueTooLong;
                data.assign(new_value);
                data.set_value_calls += 1;
            }

            fn selectRange(
                ctx: *anyopaque,
                _: []const u8,
                range: terminal_text.OffsetRange,
            ) !void {
                const data: *TestEditStateData = @ptrCast(@alignCast(ctx));
                data.selected_range = range;
                data.select_calls += 1;
            }
        };
        return .{
            .ctx = @ptrCast(self),
            .name = callbacks.name,
            .value = callbacks.value,
            .snapshot = callbacks.snapshot,
            .focused = callbacks.focused,
            .role = .edit,
            .set_value = callbacks.setValue,
            .select_range = callbacks.selectRange,
        };
    }
};

test "terminal role rejects direct Value vtable calls" {
    var data = TestEditStateData{};
    data.assign("must stay private");
    var state = data.state();
    state.role = .terminal;
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        state,
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var value: com.BSTR = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        TerminalProvider.GetValue(&provider.value_iface, &value),
    );
    try std.testing.expectEqual(@as(com.BSTR, null), value);

    var read_only: com.BOOL = 1;
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        TerminalProvider.GetIsReadOnly(&provider.value_iface, &read_only),
    );
    try std.testing.expectEqual(@as(com.BOOL, 0), read_only);

    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        TerminalProvider.SetValue(
            &provider.value_iface,
            std.unicode.utf8ToUtf16LeStringLiteral("must not replace").ptr,
        ),
    );
    try std.testing.expectEqualStrings("must stay private", data.value());
    try std.testing.expectEqual(@as(u32, 0), data.set_value_calls);
}

test "TerminalProvider normalizes visible range to UTF-8 boundaries" {
    var data = TestTerminalStateData{
        .value_text = "A🔥B界C",
        .visible_value_text = "🔥B",
        .visible_range = .{ .start = 2, .end = 8 },
    };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var range: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(com.S_OK, provider.createVisibleRange(&range));
    defer _ = TerminalTextRangeProvider.Release(range.?);

    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 1, .end = 6 },
        TerminalTextRangeProvider.fromBase(range.?).range,
    );

    var text: ?[*:0]u16 = null;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.GetText(range.?, -1, &text));
    defer com.SysFreeString(text);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("🔥B");
    try std.testing.expectEqual(@as(u32, expected.len), com.SysStringLen(text));
    try std.testing.expectEqualSlices(u16, expected, text.?[0..expected.len]);
}

test "edit provider exposes Edit Text Text2 and writable Value contracts" {
    var data = TestEditStateData{};
    data.assign("a🚀b");
    var state = data.state();
    state.use_com_threading = true;
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        state,
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var provider_options: i32 = 0;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.get_ProviderOptions(&provider.base, &provider_options));
    try std.testing.expectEqual(
        com.ProviderOptions_ServerSideProvider | com.ProviderOptions_UseComThreading,
        provider_options,
    );

    var control_type = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPropertyValue(&provider.base, constants.UIA_ControlTypePropertyId, &control_type),
    );
    try std.testing.expectEqual(constants.UIA_EditControlTypeId, control_type.value.i4);

    var text_pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&provider.base, constants.UIA_TextPatternId, &text_pattern),
    );
    try std.testing.expect(text_pattern != null);
    defer _ = TerminalProvider.TextRelease(@ptrCast(@alignCast(text_pattern.?)));

    var text2_pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&provider.base, constants.UIA_TextPattern2Id, &text2_pattern),
    );
    try std.testing.expect(text2_pattern != null);
    defer _ = TerminalProvider.Text2Release(@ptrCast(@alignCast(text2_pattern.?)));

    var value_pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&provider.base, constants.UIA_ValuePatternId, &value_pattern),
    );
    try std.testing.expect(value_pattern != null);
    defer _ = TerminalProvider.ValueRelease(@ptrCast(@alignCast(value_pattern.?)));

    var read_only: com.BOOL = 1;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetIsReadOnly(&provider.value_iface, &read_only),
    );
    try std.testing.expectEqual(@as(com.BOOL, 0), read_only);

    const replacement = std.unicode.utf8ToUtf16LeStringLiteral("next 🚀");
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.SetValue(&provider.value_iface, replacement.ptr),
    );
    try std.testing.expectEqualStrings("next 🚀", data.value());
    try std.testing.expectEqual(@as(u32, 1), data.set_value_calls);

    var value: com.BSTR = null;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.GetValue(&provider.value_iface, &value));
    defer com.SysFreeString(value);
    try std.testing.expectEqual(@as(u32, @intCast(replacement.len)), com.SysStringLen(value));
    try std.testing.expectEqualSlices(u16, replacement, value.?[0..replacement.len]);
}

test "edit provider exposes one mutable text selection" {
    var data = TestEditStateData{};
    data.assign("a🚀b");
    data.selection_range = .{ .start = 1, .end = 5 };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        data.state(),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var supported: i32 = com.SupportedTextSelection_None;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.get_SupportedTextSelection(&provider.text_iface, &supported),
    );
    try std.testing.expectEqual(com.SupportedTextSelection_Single, supported);

    var selections: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetSelection(&provider.text_iface, &selections),
    );
    defer _ = com.SafeArrayDestroy(selections);
    var index: i32 = 0;
    var selected: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(selections.?, &index, @ptrCast(&selected)),
    );
    defer _ = TerminalTextRangeProvider.Release(selected.?);
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 1, .end = 5 },
        TerminalTextRangeProvider.fromBase(selected.?).range,
    );
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.Select(selected.?));
    try std.testing.expectEqual(@as(u32, 1), data.select_calls);
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 1, .end = 5 },
        data.selected_range,
    );
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, TerminalTextRangeProvider.AddToSelection(selected.?));
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, TerminalTextRangeProvider.RemoveFromSelection(selected.?));
}

test "terminal provider exposes an active read-only selection" {
    var data = TestTerminalStateData{
        .value_text = "hello world",
        .visible_value_text = "hello world",
        .visible_range = .{ .start = 0, .end = 11 },
        .caret_offset = 11,
        .selection_range = .{ .start = 0, .end = 5 },
        .has_selection = true,
    };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    var supported: i32 = com.SupportedTextSelection_Single;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.get_SupportedTextSelection(&provider.text_iface, &supported),
    );
    try std.testing.expectEqual(com.SupportedTextSelection_None, supported);

    var selections: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetSelection(&provider.text_iface, &selections),
    );
    defer _ = com.SafeArrayDestroy(selections);
    var index: i32 = 0;
    var selected: ?*com.ITextRangeProvider = null;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(selections.?, &index, @ptrCast(&selected)),
    );
    defer _ = TerminalTextRangeProvider.Release(selected.?);
    try std.testing.expectEqual(
        terminal_text.OffsetRange{ .start = 0, .end = 5 },
        TerminalTextRangeProvider.fromBase(selected.?).range,
    );
}

test "read-only edit provider still exposes Value contract" {
    var data = TestEditStateData{};
    data.assign("read only");
    var state = data.state();
    state.set_value = null;
    var provider = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&provider.base);

    var value_pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&provider.base, constants.UIA_ValuePatternId, &value_pattern),
    );
    try std.testing.expect(value_pattern != null);
    defer _ = TerminalProvider.ValueRelease(@ptrCast(@alignCast(value_pattern.?)));

    var read_only: com.BOOL = 0;
    try std.testing.expectEqual(com.S_OK, TerminalProvider.GetIsReadOnly(&provider.value_iface, &read_only));
    try std.testing.expectEqual(@as(com.BOOL, 1), read_only);
    var help_text = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPropertyValue(&provider.base, constants.UIA_HelpTextPropertyId, &help_text),
    );
    defer com.SysFreeString(help_text.value.bstr);
    const expected_help = std.unicode.utf8ToUtf16LeStringLiteral("Read-only text");
    try std.testing.expectEqualSlices(u16, expected_help, help_text.value.bstr.?[0..expected_help.len]);
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        TerminalProvider.SetValue(
            &provider.value_iface,
            std.unicode.utf8ToUtf16LeStringLiteral("blocked").ptr,
        ),
    );
}

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

    var selection: ?*com.SAFEARRAY = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        TerminalProvider.GetSelection(&provider.text_iface, &selection),
    );
    try std.testing.expect(selection == null);

    var read_only: com.BOOL = 1;
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        TerminalProvider.GetIsReadOnly(&provider.value_iface, &read_only),
    );
    try std.testing.expectEqual(@as(com.BOOL, 0), read_only);

    var supported_selection: i32 = com.SupportedTextSelection_Single;
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        TerminalProvider.get_SupportedTextSelection(&provider.text_iface, &supported_selection),
    );
    try std.testing.expectEqual(com.SupportedTextSelection_None, supported_selection);
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

    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, TerminalTextRangeProvider.Select(&range.base));
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, TerminalTextRangeProvider.AddToSelection(&range.base));
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, TerminalTextRangeProvider.RemoveFromSelection(&range.base));
    try std.testing.expectEqual(com.E_NOTIMPL, TerminalTextRangeProvider.ScrollIntoView(&range.base, 1));
}

test "TerminalProvider maps hidden native windows to UIA offscreen" {
    try std.testing.expect(windowVisibilityIsOffscreen(0));
    try std.testing.expect(!windowVisibilityIsOffscreen(1));
    try std.testing.expect(settingsControlIsOffscreen(0, false));
    try std.testing.expect(settingsControlIsOffscreen(1, true));
    try std.testing.expect(!settingsControlIsOffscreen(1, false));
}

test "uia ChromeControlProvider exposes live chrome patterns and detaches safely" {
    const Context = struct {
        selected_tag: usize = 1,
        toggle_on: bool = true,
        name_calls: usize = 0,
        container: ?*ChromeControlProvider = null,
        selected_item: ?*ChromeControlProvider = null,

        fn name(ctx: *anyopaque, tag: usize, buf: []u8) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.name_calls += 1;
            return std.fmt.bufPrint(buf, "chrome {d}", .{tag}) catch "";
        }
        fn selected(ctx: *anyopaque, tag: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.selected_tag == tag;
        }
        fn selectedProvider(ctx: *anyopaque) ?*ChromeControlProvider {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.selected_item;
        }
        fn selectionContainer(ctx: *anyopaque) ?*ChromeControlProvider {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.container;
        }
        fn toggled(ctx: *anyopaque, _: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.toggle_on;
        }
        fn rangeValue(_: *anyopaque) ChromeRangeValue {
            return .{
                .value = 25,
                .minimum = 0,
                .maximum = 100,
                .large_change = 10,
                .small_change = 1,
            };
        }
    };

    const GetDesktopWindow = struct {
        extern "user32" fn GetDesktopWindow() callconv(.winapi) com.HWND;
    }.GetDesktopWindow;
    const hwnd = GetDesktopWindow();
    var context: Context = .{};
    const context_ptr: *anyopaque = @ptrCast(&context);
    const container = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .tab_container,
        .name = Context.name,
        .selected_provider = Context.selectedProvider,
    });
    defer _ = ChromeControlProvider.Release(&container.base);
    defer container.detach();
    context.container = container;

    const item = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .tab_item,
        .tag = 1,
        .name = Context.name,
        .selected = Context.selected,
        .selection_container = Context.selectionContainer,
    });
    defer _ = ChromeControlProvider.Release(&item.base);
    defer item.detach();
    context.selected_item = item;

    const toggle = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .toggle,
        .tag = 2,
        .name = Context.name,
        .toggled = Context.toggled,
    });
    defer _ = ChromeControlProvider.Release(&toggle.base);
    defer toggle.detach();

    const scrollbar = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .scrollbar,
        .name = Context.name,
        .range_value = Context.rangeValue,
    });
    defer _ = ChromeControlProvider.Release(&scrollbar.base);
    defer scrollbar.detach();

    const live_text = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .live_text,
        .tag = 3,
        .name = Context.name,
    });
    defer _ = ChromeControlProvider.Release(&live_text.base);
    defer live_text.detach();

    const decorative = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .decorative,
        .name = Context.name,
    });
    defer _ = ChromeControlProvider.Release(&decorative.base);
    defer decorative.detach();

    var value = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.GetPropertyValue(&container.base, constants.UIA_ControlTypePropertyId, &value),
    );
    try std.testing.expectEqual(constants.UIA_TabControlTypeId, value.value.i4);

    var first_name = com.VARIANT.empty();
    defer _ = com.VariantClear(&first_name);
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.GetPropertyValue(&item.base, constants.UIA_NamePropertyId, &first_name),
    );
    var second_name = com.VARIANT.empty();
    defer _ = com.VariantClear(&second_name);
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.GetPropertyValue(&item.base, constants.UIA_NamePropertyId, &second_name),
    );
    const expected_name = std.unicode.utf8ToUtf16LeStringLiteral("chrome 1");
    try std.testing.expect(first_name.value.bstr != null);
    try std.testing.expect(second_name.value.bstr != null);
    try std.testing.expect(first_name.value.bstr.? != second_name.value.bstr.?);
    try std.testing.expectEqualSlices(u16, expected_name, first_name.value.bstr.?[0..expected_name.len]);

    var pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.GetPatternProvider(&container.base, constants.UIA_SelectionPatternId, &pattern),
    );
    try std.testing.expect(pattern == @as(?*com.IUnknown, @ptrCast(&container.selection_iface)));
    _ = ChromeControlProvider.SelectionRelease(@ptrCast(@alignCast(pattern.?)));

    var selection: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetSelection(&container.selection_iface, &selection));
    defer _ = com.SafeArrayDestroy(selection);
    var selected_unknown: ?*com.IUnknown = null;
    var selected_index: i32 = 0;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(selection.?, &selected_index, @ptrCast(&selected_unknown)),
    );
    defer _ = selected_unknown.?.vtbl.Release(selected_unknown.?);
    try std.testing.expect(selected_unknown == @as(?*com.IUnknown, @ptrCast(&item.base)));

    var selected: com.BOOL = 0;
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetIsSelected(&item.selection_item_iface, &selected));
    try std.testing.expectEqual(@as(com.BOOL, 1), selected);
    var selection_container: ?*com.IRawElementProviderSimple = null;
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.GetSelectionContainer(&item.selection_item_iface, &selection_container),
    );
    try std.testing.expect(selection_container == &container.base);
    _ = ChromeControlProvider.Release(selection_container.?);

    pattern = null;
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.GetPatternProvider(&toggle.base, constants.UIA_TogglePatternId, &pattern),
    );
    try std.testing.expect(pattern == @as(?*com.IUnknown, @ptrCast(&toggle.toggle_iface)));
    _ = ChromeControlProvider.ToggleRelease(@ptrCast(@alignCast(pattern.?)));
    var toggle_state: i32 = 0;
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetToggleState(&toggle.toggle_iface, &toggle_state));
    try std.testing.expectEqual(@as(i32, 1), toggle_state);

    var range_value: f64 = 0;
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetRangeValue(&scrollbar.range_iface, &range_value));
    try std.testing.expectEqual(@as(f64, 25), range_value);
    var read_only: com.BOOL = 0;
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetRangeIsReadOnly(&scrollbar.range_iface, &read_only));
    try std.testing.expectEqual(@as(com.BOOL, 1), read_only);
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        ChromeControlProvider.SetRangeValue(&scrollbar.range_iface, 50),
    );

    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.GetPropertyValue(&live_text.base, constants.UIA_LiveSettingPropertyId, &value),
    );
    try std.testing.expectEqual(constants.LiveSetting_Polite, value.value.i4);
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.GetPropertyValue(&decorative.base, constants.UIA_IsControlElementPropertyId, &value),
    );
    try std.testing.expectEqual(com.VARIANT_FALSE, value.value.bool_val);

    const calls_before_detach = context.name_calls;
    item.detach();
    item.detach();
    var detached_unknown: ?*anyopaque = null;
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.QueryInterface(&item.base, &com.IID_IUnknown, &detached_unknown),
    );
    try std.testing.expect(detached_unknown == @as(?*anyopaque, @ptrCast(&item.base)));
    _ = ChromeControlProvider.Release(@ptrCast(@alignCast(detached_unknown.?)));
    value = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        ChromeControlProvider.GetPropertyValue(&item.base, constants.UIA_NamePropertyId, &value),
    );
    try std.testing.expectEqual(calls_before_detach, context.name_calls);
}

test "ChromeControlProvider tab items enforce required single selection" {
    const Context = struct {
        selected_tag: usize = 1,

        fn name(_: *anyopaque, tag: usize, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "tab {d}", .{tag}) catch "";
        }
        fn selected(ctx: *anyopaque, tag: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.selected_tag == tag;
        }
    };

    const GetDesktopWindow = struct {
        extern "user32" fn GetDesktopWindow() callconv(.winapi) com.HWND;
    }.GetDesktopWindow;
    const hwnd = GetDesktopWindow();
    var context: Context = .{};
    const context_ptr: *anyopaque = @ptrCast(&context);

    const selected_tab = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .tab_item,
        .tag = 1,
        .name = Context.name,
        .selected = Context.selected,
    });
    defer _ = ChromeControlProvider.Release(&selected_tab.base);
    defer selected_tab.detach();

    const unselected_tab = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .tab_item,
        .tag = 2,
        .name = Context.name,
        .selected = Context.selected,
    });
    defer _ = ChromeControlProvider.Release(&unselected_tab.base);
    defer unselected_tab.detach();

    // CanSelectMultiple is false, so AddToSelection may only confirm an
    // already selected tab; it must never switch tabs behind the client.
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.AddToSelection(&selected_tab.selection_item_iface),
    );
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        ChromeControlProvider.AddToSelection(&unselected_tab.selection_item_iface),
    );

    // IsSelectionRequired is true, so the selected tab cannot be deselected.
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        ChromeControlProvider.RemoveFromSelection(&selected_tab.selection_item_iface),
    );
    try std.testing.expectEqual(
        com.S_OK,
        ChromeControlProvider.RemoveFromSelection(&unselected_tab.selection_item_iface),
    );

    try std.testing.expectEqual(@as(usize, 1), context.selected_tag);
}

test "ChromeControlProvider disconnect latches only after UIA releases it" {
    const Context = struct {
        fn name(_: *anyopaque, tag: usize, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "chrome {d}", .{tag}) catch "";
        }
    };

    var context: usize = 0;
    const provider = try ChromeControlProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        .{
            .ctx = @ptrCast(&context),
            .role = .decorative,
            .name = Context.name,
        },
    );
    defer _ = ChromeControlProvider.Release(&provider.base);

    // A transient input-sync rejection must leave the provider undisconnected
    // so the deferred retry reaches UIA again instead of short circuiting to
    // S_OK and releasing the creation reference on a registered provider.
    try std.testing.expectEqual(
        com.RPC_E_CANTCALLOUT_ININPUTSYNCCALL,
        provider.finishDisconnect(com.RPC_E_CANTCALLOUT_ININPUTSYNCCALL),
    );
    try std.testing.expect(!provider.disconnected.load(.acquire));

    try std.testing.expectEqual(com.S_OK, provider.finishDisconnect(com.S_OK));
    try std.testing.expect(provider.disconnected.load(.acquire));

    // Disconnect stays idempotent once UIA has released the provider.
    try std.testing.expectEqual(com.S_OK, provider.disconnect());
    try std.testing.expect(provider.disconnected.load(.acquire));
}

test "SettingsControlProvider exposes ValueProvider only for edit controls" {
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        SettingsControlProvider.setValuePrecondition(false, .edit, true),
    );
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        SettingsControlProvider.setValuePrecondition(true, .button, true),
    );
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTENABLED,
        SettingsControlProvider.setValuePrecondition(true, .edit, false),
    );
    try std.testing.expectEqual(
        com.S_OK,
        SettingsControlProvider.setValuePrecondition(true, .edit, true),
    );

    var edit = try SettingsControlProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .edit,
        "Scrollback limit",
    );
    defer _ = SettingsControlProvider.Release(&edit.base);

    var value: ?*anyopaque = null;
    try std.testing.expectEqual(
        com.S_OK,
        SettingsControlProvider.QueryInterface(&edit.base, &com.IID_IValueProvider, &value),
    );
    try std.testing.expect(value == @as(?*anyopaque, @ptrCast(&edit.value_iface)));
    try std.testing.expectEqual(@as(u32, 1), SettingsControlProvider.ValueRelease(@ptrCast(@alignCast(value.?))));

    var text = try SettingsControlProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .text,
        "Terminal",
    );
    defer _ = SettingsControlProvider.Release(&text.base);
    value = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.E_NOINTERFACE,
        SettingsControlProvider.QueryInterface(&text.base, &com.IID_IValueProvider, &value),
    );
    try std.testing.expect(value == null);
}

test "SettingsControlProvider exposes InvokeProvider only for buttons" {
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        SettingsControlProvider.invokePrecondition(false, .button, true),
    );
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        SettingsControlProvider.invokePrecondition(true, .edit, true),
    );
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTENABLED,
        SettingsControlProvider.invokePrecondition(true, .button, false),
    );
    try std.testing.expectEqual(
        com.S_OK,
        SettingsControlProvider.invokePrecondition(true, .button, true),
    );

    var button = try SettingsControlProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .button,
        "Save and close",
    );
    defer _ = SettingsControlProvider.Release(&button.base);

    var invoke: ?*anyopaque = null;
    try std.testing.expectEqual(
        com.S_OK,
        SettingsControlProvider.QueryInterface(&button.base, &com.IID_IInvokeProvider, &invoke),
    );
    try std.testing.expect(invoke == @as(?*anyopaque, @ptrCast(&button.invoke_iface)));
    try std.testing.expectEqual(@as(u32, 1), SettingsControlProvider.InvokeRelease(@ptrCast(@alignCast(invoke.?))));

    var edit = try SettingsControlProvider.create(
        std.testing.allocator,
        @ptrFromInt(1),
        .edit,
        "Scrollback limit",
    );
    defer _ = SettingsControlProvider.Release(&edit.base);
    invoke = @ptrFromInt(0x10);
    try std.testing.expectEqual(
        com.E_NOINTERFACE,
        SettingsControlProvider.QueryInterface(&edit.base, &com.IID_IInvokeProvider, &invoke),
    );
    try std.testing.expect(invoke == null);
}

test "settings provider behavior invoke dispatch is asynchronous and source preserving" {
    const win32 = struct {
        const MSG = extern struct {
            hwnd: ?com.HWND,
            message: u32,
            wParam: com.WPARAM,
            lParam: com.LPARAM,
            time: u32,
            pt: POINT,
            lPrivate: u32,
        };

        extern "user32" fn CreateWindowExW(
            dwExStyle: u32,
            lpClassName: [*:0]const u16,
            lpWindowName: [*:0]const u16,
            dwStyle: u32,
            x: i32,
            y: i32,
            nWidth: i32,
            nHeight: i32,
            hWndParent: ?com.HWND,
            hMenu: ?*anyopaque,
            hInstance: ?*anyopaque,
            lpParam: ?*anyopaque,
        ) callconv(.winapi) ?com.HWND;
        extern "user32" fn DefWindowProcW(
            hWnd: com.HWND,
            Msg: u32,
            wParam: com.WPARAM,
            lParam: com.LPARAM,
        ) callconv(.winapi) com.LRESULT;
        extern "user32" fn DestroyWindow(hWnd: com.HWND) callconv(.winapi) com.BOOL;
        extern "user32" fn SetWindowLongPtrW(
            hWnd: com.HWND,
            nIndex: i32,
            dwNewLong: isize,
        ) callconv(.winapi) isize;
        extern "user32" fn PeekMessageW(
            lpMsg: *MSG,
            hWnd: ?com.HWND,
            wMsgFilterMin: u32,
            wMsgFilterMax: u32,
            wRemoveMsg: u32,
        ) callconv(.winapi) com.BOOL;
        extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) com.LRESULT;
    };
    const fixture = struct {
        var command_calls: usize = 0;
        var last_wparam: com.WPARAM = 0;
        var last_lparam: com.LPARAM = 0;

        fn wndProc(
            hwnd: com.HWND,
            message: u32,
            wparam: com.WPARAM,
            lparam: com.LPARAM,
        ) callconv(.winapi) com.LRESULT {
            if (message == WM_COMMAND) {
                command_calls += 1;
                last_wparam = wparam;
                last_lparam = lparam;
                return 1;
            }
            return win32.DefWindowProcW(hwnd, message, wparam, lparam);
        }
    };

    fixture.command_calls = 0;
    fixture.last_wparam = 0;
    fixture.last_lparam = 0;

    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
    const empty_title = std.unicode.utf8ToUtf16LeStringLiteral("");
    const parent = win32.CreateWindowExW(
        0,
        static_class,
        empty_title,
        0,
        0,
        0,
        100,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(parent);
    try std.testing.expect(win32.SetWindowLongPtrW(
        parent,
        -4,
        @intCast(@intFromPtr(&fixture.wndProc)),
    ) != 0);

    const child = win32.CreateWindowExW(
        0,
        button_class,
        empty_title,
        0x40000000,
        0,
        0,
        80,
        24,
        parent,
        @ptrFromInt(41),
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(child);
    const provider = try SettingsControlProvider.create(
        std.testing.allocator,
        child,
        .button,
        "Save",
    );
    defer _ = SettingsControlProvider.Release(&provider.base);

    try std.testing.expectEqual(
        com.S_OK,
        SettingsControlProvider.Invoke(&provider.invoke_iface),
    );
    try std.testing.expectEqual(@as(usize, 0), fixture.command_calls);

    var message: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(
        &message,
        parent,
        WM_COMMAND,
        WM_COMMAND,
        1,
    ) != 0);
    _ = win32.DispatchMessageW(&message);
    try std.testing.expectEqual(@as(usize, 1), fixture.command_calls);
    try std.testing.expectEqual(@as(com.WPARAM, 41), fixture.last_wparam);
    try std.testing.expectEqual(
        @as(com.LPARAM, @bitCast(@intFromPtr(child))),
        fixture.last_lparam,
    );
}

test "settings provider behavior selection dispatch is synchronous and postcondition checked" {
    const win32 = struct {
        extern "user32" fn CreateWindowExW(
            dwExStyle: u32,
            lpClassName: [*:0]const u16,
            lpWindowName: [*:0]const u16,
            dwStyle: u32,
            x: i32,
            y: i32,
            nWidth: i32,
            nHeight: i32,
            hWndParent: ?com.HWND,
            hMenu: ?*anyopaque,
            hInstance: ?*anyopaque,
            lpParam: ?*anyopaque,
        ) callconv(.winapi) ?com.HWND;
        extern "user32" fn DefWindowProcW(
            hWnd: com.HWND,
            Msg: u32,
            wParam: com.WPARAM,
            lParam: com.LPARAM,
        ) callconv(.winapi) com.LRESULT;
        extern "user32" fn DestroyWindow(hWnd: com.HWND) callconv(.winapi) com.BOOL;
        extern "user32" fn SetWindowLongPtrW(
            hWnd: com.HWND,
            nIndex: i32,
            dwNewLong: isize,
        ) callconv(.winapi) isize;
    };
    const fixture = struct {
        var group: ?*SettingsSectionGroupProvider = null;
        var update_selection = false;
        var command_calls: usize = 0;
        var last_wparam: com.WPARAM = 0;
        var last_lparam: com.LPARAM = 0;

        fn wndProc(
            hwnd: com.HWND,
            message: u32,
            wparam: com.WPARAM,
            lparam: com.LPARAM,
        ) callconv(.winapi) com.LRESULT {
            if (message == WM_COMMAND) {
                command_calls += 1;
                last_wparam = wparam;
                last_lparam = lparam;
                if (update_selection) group.?.setSelected(0);
                return 1;
            }
            return win32.DefWindowProcW(hwnd, message, wparam, lparam);
        }
    };

    fixture.group = null;
    fixture.update_selection = false;
    fixture.command_calls = 0;
    fixture.last_wparam = 0;
    fixture.last_lparam = 0;

    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
    const empty_title = std.unicode.utf8ToUtf16LeStringLiteral("");
    const parent = win32.CreateWindowExW(
        0,
        static_class,
        empty_title,
        0,
        0,
        0,
        100,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(parent);
    try std.testing.expect(win32.SetWindowLongPtrW(
        parent,
        -4,
        @intCast(@intFromPtr(&fixture.wndProc)),
    ) != 0);

    const child = win32.CreateWindowExW(
        0,
        button_class,
        empty_title,
        0x40000000,
        0,
        0,
        80,
        24,
        parent,
        @ptrFromInt(42),
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(child);

    const group = try SettingsSectionGroupProvider.create(std.testing.allocator, parent);
    const section = try SettingsSectionProvider.create(
        std.testing.allocator,
        child,
        "Appearance",
        0,
        group,
    );
    group.setSection(0, section);
    fixture.group = group;
    defer {
        fixture.group = null;
        group.detach();
        section.detach();
        _ = SettingsSectionProvider.Release(&section.base);
        _ = SettingsSectionGroupProvider.Release(&group.base);
    }

    fixture.update_selection = true;
    try std.testing.expectEqual(
        com.S_OK,
        SettingsSectionProvider.Select(&section.selection_iface),
    );
    try std.testing.expect(section.isSelected());
    try std.testing.expectEqual(@as(usize, 1), fixture.command_calls);
    try std.testing.expectEqual(@as(com.WPARAM, 42), fixture.last_wparam);
    try std.testing.expectEqual(
        @as(com.LPARAM, @bitCast(@intFromPtr(child))),
        fixture.last_lparam,
    );

    group.setSelected(1);
    fixture.update_selection = false;
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        SettingsSectionProvider.Select(&section.selection_iface),
    );
    try std.testing.expect(!section.isSelected());
    try std.testing.expectEqual(@as(usize, 2), fixture.command_calls);
}

test "settings provider behavior selection dispatch is bounded for a hung owner thread" {
    const win32 = struct {
        const MSG = extern struct {
            hwnd: ?com.HWND,
            message: u32,
            wParam: com.WPARAM,
            lParam: com.LPARAM,
            time: u32,
            pt: POINT,
            lPrivate: u32,
        };

        const WAIT_OBJECT_0: u32 = 0;
        const WAIT_TIMEOUT: u32 = 258;
        const INFINITE: u32 = 0xFFFFFFFF;
        const PM_REMOVE: u32 = 0x0001;

        extern "kernel32" fn CreateEventW(
            lpEventAttributes: ?*anyopaque,
            bManualReset: com.BOOL,
            bInitialState: com.BOOL,
            lpName: ?[*:0]const u16,
        ) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn SetEvent(hEvent: *anyopaque) callconv(.winapi) com.BOOL;
        extern "kernel32" fn WaitForSingleObject(
            hHandle: *anyopaque,
            dwMilliseconds: u32,
        ) callconv(.winapi) u32;
        extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) com.BOOL;
        extern "user32" fn CreateWindowExW(
            dwExStyle: u32,
            lpClassName: [*:0]const u16,
            lpWindowName: [*:0]const u16,
            dwStyle: u32,
            x: i32,
            y: i32,
            nWidth: i32,
            nHeight: i32,
            hWndParent: ?com.HWND,
            hMenu: ?*anyopaque,
            hInstance: ?*anyopaque,
            lpParam: ?*anyopaque,
        ) callconv(.winapi) ?com.HWND;
        extern "user32" fn DefWindowProcW(
            hWnd: com.HWND,
            Msg: u32,
            wParam: com.WPARAM,
            lParam: com.LPARAM,
        ) callconv(.winapi) com.LRESULT;
        extern "user32" fn DestroyWindow(hWnd: com.HWND) callconv(.winapi) com.BOOL;
        extern "user32" fn SetWindowLongPtrW(
            hWnd: com.HWND,
            nIndex: i32,
            dwNewLong: isize,
        ) callconv(.winapi) isize;
        extern "user32" fn PeekMessageW(
            lpMsg: *MSG,
            hWnd: ?com.HWND,
            wMsgFilterMin: u32,
            wMsgFilterMax: u32,
            wRemoveMsg: u32,
        ) callconv(.winapi) com.BOOL;
    };
    const Fixture = struct {
        var active: ?*@This() = null;

        ready_event: *anyopaque,
        release_event: *anyopaque,
        owner_released_event: *anyopaque,
        destroy_event: *anyopaque,
        select_done_event: *anyopaque,
        parent: ?com.HWND,
        child: ?com.HWND,
        section: ?*SettingsSectionProvider,
        owner_setup_ok: std.atomic.Value(bool),
        owner_thread_calls: std.atomic.Value(usize),
        select_calls: std.atomic.Value(usize),
        command_calls: std.atomic.Value(usize),
        select_result: std.atomic.Value(com.HRESULT),

        fn wndProc(
            hwnd: com.HWND,
            message: u32,
            wparam: com.WPARAM,
            lparam: com.LPARAM,
        ) callconv(.winapi) com.LRESULT {
            const self = active orelse return win32.DefWindowProcW(hwnd, message, wparam, lparam);
            if (message == WM_COMMAND) {
                _ = self.command_calls.fetchAdd(1, .acq_rel);
                return 1;
            }
            return win32.DefWindowProcW(hwnd, message, wparam, lparam);
        }

        fn ownerMain(self: *@This()) void {
            _ = self.owner_thread_calls.fetchAdd(1, .acq_rel);
            const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
            const button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
            const empty_title = std.unicode.utf8ToUtf16LeStringLiteral("");
            const parent = win32.CreateWindowExW(
                0,
                static_class,
                empty_title,
                0,
                0,
                0,
                100,
                100,
                null,
                null,
                null,
                null,
            ) orelse {
                _ = win32.SetEvent(self.ready_event);
                return;
            };
            self.parent = parent;
            if (win32.SetWindowLongPtrW(
                parent,
                -4,
                @intCast(@intFromPtr(&wndProc)),
            ) == 0) {
                _ = win32.DestroyWindow(parent);
                self.parent = null;
                _ = win32.SetEvent(self.ready_event);
                return;
            }
            const child = win32.CreateWindowExW(
                0,
                button_class,
                empty_title,
                0x40000000,
                0,
                0,
                80,
                24,
                parent,
                @ptrFromInt(44),
                null,
                null,
            ) orelse {
                _ = win32.DestroyWindow(parent);
                self.parent = null;
                _ = win32.SetEvent(self.ready_event);
                return;
            };
            self.child = child;
            self.owner_setup_ok.store(true, .release);
            _ = win32.SetEvent(self.ready_event);

            // Deliberately do not pump this owner thread until the watchdog
            // releases it. PeekMessage then drains any mutation-induced
            // unbounded synchronous send so the fixture can shut down safely.
            _ = win32.WaitForSingleObject(self.release_event, win32.INFINITE);
            var message: win32.MSG = undefined;
            _ = win32.PeekMessageW(&message, parent, WM_COMMAND, WM_COMMAND, win32.PM_REMOVE);
            _ = win32.SetEvent(self.owner_released_event);
            _ = win32.WaitForSingleObject(self.destroy_event, win32.INFINITE);
            _ = win32.DestroyWindow(child);
            _ = win32.DestroyWindow(parent);
        }

        fn selectMain(self: *@This()) void {
            _ = self.select_calls.fetchAdd(1, .acq_rel);
            const result = SettingsSectionProvider.Select(&self.section.?.selection_iface);
            self.select_result.store(result, .release);
            _ = win32.SetEvent(self.select_done_event);
        }
    };

    const ready_event = win32.CreateEventW(null, 1, 0, null) orelse return error.TestUnexpectedResult;
    defer _ = win32.CloseHandle(ready_event);
    const release_event = win32.CreateEventW(null, 1, 0, null) orelse return error.TestUnexpectedResult;
    defer _ = win32.CloseHandle(release_event);
    const owner_released_event = win32.CreateEventW(null, 1, 0, null) orelse return error.TestUnexpectedResult;
    defer _ = win32.CloseHandle(owner_released_event);
    const destroy_event = win32.CreateEventW(null, 1, 0, null) orelse return error.TestUnexpectedResult;
    defer _ = win32.CloseHandle(destroy_event);
    const select_done_event = win32.CreateEventW(null, 1, 0, null) orelse return error.TestUnexpectedResult;
    defer _ = win32.CloseHandle(select_done_event);

    var fixture: Fixture = .{
        .ready_event = ready_event,
        .release_event = release_event,
        .owner_released_event = owner_released_event,
        .destroy_event = destroy_event,
        .select_done_event = select_done_event,
        .parent = null,
        .child = null,
        .section = null,
        .owner_setup_ok = std.atomic.Value(bool).init(false),
        .owner_thread_calls = std.atomic.Value(usize).init(0),
        .select_calls = std.atomic.Value(usize).init(0),
        .command_calls = std.atomic.Value(usize).init(0),
        .select_result = std.atomic.Value(com.HRESULT).init(com.E_NOTIMPL),
    };
    Fixture.active = &fixture;
    defer Fixture.active = null;
    const owner_thread = try std.Thread.spawn(.{}, Fixture.ownerMain, .{&fixture});
    var owner_joined = false;
    defer if (!owner_joined) {
        _ = win32.SetEvent(release_event);
        _ = win32.SetEvent(destroy_event);
        owner_thread.join();
    };

    try std.testing.expectEqual(
        win32.WAIT_OBJECT_0,
        win32.WaitForSingleObject(ready_event, win32.INFINITE),
    );
    try std.testing.expect(fixture.owner_setup_ok.load(.acquire));
    const parent = fixture.parent orelse return error.TestUnexpectedResult;
    const child = fixture.child orelse return error.TestUnexpectedResult;
    const group = try SettingsSectionGroupProvider.create(std.testing.allocator, parent);
    const section = try SettingsSectionProvider.create(
        std.testing.allocator,
        child,
        "Keyboard shortcuts",
        0,
        group,
    );
    group.setSection(0, section);
    fixture.section = section;
    defer {
        fixture.section = null;
        group.detach();
        section.detach();
        _ = SettingsSectionProvider.Release(&section.base);
        _ = SettingsSectionGroupProvider.Release(&group.base);
    }

    const select_thread = try std.Thread.spawn(.{}, Fixture.selectMain, .{&fixture});
    defer select_thread.join();
    const select_wait = win32.WaitForSingleObject(select_done_event, 4000);
    try std.testing.expect(select_wait == win32.WAIT_OBJECT_0 or select_wait == win32.WAIT_TIMEOUT);

    _ = win32.SetEvent(release_event);
    try std.testing.expectEqual(
        win32.WAIT_OBJECT_0,
        win32.WaitForSingleObject(owner_released_event, win32.INFINITE),
    );
    if (select_wait == win32.WAIT_TIMEOUT) {
        _ = win32.WaitForSingleObject(select_done_event, win32.INFINITE);
    }
    _ = win32.SetEvent(destroy_event);
    owner_thread.join();
    owner_joined = true;

    try std.testing.expectEqual(win32.WAIT_OBJECT_0, select_wait);
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTAVAILABLE, fixture.select_result.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fixture.owner_thread_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fixture.select_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fixture.command_calls.load(.acquire));
}

test "settings provider behavior keyboard focus includes descendants" {
    const win32 = struct {
        extern "user32" fn CreateWindowExW(
            dwExStyle: u32,
            lpClassName: [*:0]const u16,
            lpWindowName: [*:0]const u16,
            dwStyle: u32,
            x: i32,
            y: i32,
            nWidth: i32,
            nHeight: i32,
            hWndParent: ?com.HWND,
            hMenu: ?*anyopaque,
            hInstance: ?*anyopaque,
            lpParam: ?*anyopaque,
        ) callconv(.winapi) ?com.HWND;
        extern "user32" fn DestroyWindow(hWnd: com.HWND) callconv(.winapi) com.BOOL;
        extern "user32" fn SetFocus(hWnd: com.HWND) callconv(.winapi) ?com.HWND;
    };

    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const empty_title = std.unicode.utf8ToUtf16LeStringLiteral("");
    const parent = win32.CreateWindowExW(
        0,
        static_class,
        empty_title,
        0,
        0,
        0,
        100,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(parent);
    const child = win32.CreateWindowExW(
        0,
        edit_class,
        empty_title,
        0x40000000,
        0,
        0,
        80,
        24,
        parent,
        @ptrFromInt(43),
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(child);
    const peer = win32.CreateWindowExW(
        0,
        static_class,
        empty_title,
        0,
        0,
        0,
        100,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(peer);

    _ = win32.SetFocus(child);
    try std.testing.expect(hwndHasKeyboardFocus(child));
    try std.testing.expect(hwndHasKeyboardFocus(parent));
    try std.testing.expect(!hwndHasKeyboardFocus(peer));

    _ = win32.SetFocus(peer);
    try std.testing.expect(hwndHasKeyboardFocus(peer));
    try std.testing.expect(!hwndHasKeyboardFocus(child));
    try std.testing.expect(!hwndHasKeyboardFocus(parent));
}

test "settings provider behavior focus properties are provider routed and thread correct" {
    const win32 = struct {
        extern "user32" fn CreateWindowExW(
            dwExStyle: u32,
            lpClassName: [*:0]const u16,
            lpWindowName: [*:0]const u16,
            dwStyle: u32,
            x: i32,
            y: i32,
            nWidth: i32,
            nHeight: i32,
            hWndParent: ?com.HWND,
            hMenu: ?*anyopaque,
            hInstance: ?*anyopaque,
            lpParam: ?*anyopaque,
        ) callconv(.winapi) ?com.HWND;
        extern "user32" fn DestroyWindow(hWnd: com.HWND) callconv(.winapi) com.BOOL;
        extern "user32" fn SetFocus(hWnd: com.HWND) callconv(.winapi) ?com.HWND;
    };
    const fixture = struct {
        var control_property_queries: usize = 0;
        var section_property_queries: usize = 0;
        var focus_event_calls: usize = 0;

        fn queryControl(provider: *SettingsControlProvider) !bool {
            control_property_queries += 1;
            var value = com.VARIANT.empty();
            try std.testing.expectEqual(
                com.S_OK,
                provider.base.vtbl.GetPropertyValue(
                    &provider.base,
                    constants.UIA_HasKeyboardFocusPropertyId,
                    &value,
                ),
            );
            try std.testing.expectEqual(com.VT_BOOL, value.vt);
            return value.value.bool_val == com.VARIANT_TRUE;
        }

        fn querySection(provider: *SettingsSectionProvider) !bool {
            section_property_queries += 1;
            var value = com.VARIANT.empty();
            try std.testing.expectEqual(
                com.S_OK,
                provider.base.vtbl.GetPropertyValue(
                    &provider.base,
                    constants.UIA_HasKeyboardFocusPropertyId,
                    &value,
                ),
            );
            try std.testing.expectEqual(com.VT_BOOL, value.vt);
            return value.value.bool_val == com.VARIANT_TRUE;
        }

        fn raiseControl(provider: *SettingsControlProvider) void {
            focus_event_calls += 1;
            provider.raiseFocusChanged();
        }

        fn raiseSection(provider: *SettingsSectionProvider) void {
            focus_event_calls += 1;
            provider.raiseFocusChanged();
        }
    };

    fixture.control_property_queries = 0;
    fixture.section_property_queries = 0;
    fixture.focus_event_calls = 0;

    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
    const empty_title = std.unicode.utf8ToUtf16LeStringLiteral("");
    const parent = win32.CreateWindowExW(
        0,
        static_class,
        empty_title,
        0,
        0,
        0,
        100,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(parent);
    const child = win32.CreateWindowExW(
        0,
        button_class,
        empty_title,
        0x40000000,
        0,
        0,
        80,
        24,
        parent,
        @ptrFromInt(45),
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(child);
    const peer = win32.CreateWindowExW(
        0,
        static_class,
        empty_title,
        0,
        0,
        0,
        100,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(peer);

    const control = try SettingsControlProvider.create(
        std.testing.allocator,
        parent,
        .button,
        "Settings",
    );
    defer {
        _ = control.disconnect();
        _ = SettingsControlProvider.Release(&control.base);
    }
    const group = try SettingsSectionGroupProvider.create(std.testing.allocator, parent);
    const section = try SettingsSectionProvider.create(
        std.testing.allocator,
        child,
        "Appearance",
        0,
        group,
    );
    group.setSection(0, section);
    defer {
        _ = section.disconnect();
        _ = group.disconnect();
        _ = SettingsSectionProvider.Release(&section.base);
        _ = SettingsSectionGroupProvider.Release(&group.base);
    }

    var disconnected_all = false;
    defer if (!disconnected_all) {
        _ = com.UiaDisconnectAllProviders();
    };
    _ = win32.SetFocus(child);
    try std.testing.expect(try fixture.queryControl(control));
    try std.testing.expect(try fixture.querySection(section));
    fixture.raiseControl(control);
    fixture.raiseSection(section);

    _ = win32.SetFocus(peer);
    try std.testing.expect(!try fixture.queryControl(control));
    try std.testing.expect(!try fixture.querySection(section));
    try std.testing.expectEqual(com.S_OK, com.UiaDisconnectAllProviders());
    disconnected_all = true;

    try std.testing.expectEqual(@as(usize, 2), fixture.control_property_queries);
    try std.testing.expectEqual(@as(usize, 2), fixture.section_property_queries);
    try std.testing.expectEqual(@as(usize, 2), fixture.focus_event_calls);
}

test "SettingsSectionProvider preserves required single-selection semantics" {
    try std.testing.expectEqual(com.S_OK, settingsSectionAddToSelectionResult(true));
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, settingsSectionAddToSelectionResult(false));
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, settingsSectionRemoveFromSelectionResult(true));
    try std.testing.expectEqual(com.S_OK, settingsSectionRemoveFromSelectionResult(false));
}

test "SettingsSectionProvider retains its selection container without a cycle" {
    const fake_hwnd: com.HWND = @ptrFromInt(1);
    const group = try SettingsSectionGroupProvider.create(std.testing.allocator, fake_hwnd);
    try std.testing.expectEqual(@as(u32, 1), group.refcount.load(.acquire));

    const section = try SettingsSectionProvider.create(
        std.testing.allocator,
        fake_hwnd,
        "Appearance",
        0,
        group,
    );
    try std.testing.expectEqual(@as(u32, 2), group.refcount.load(.acquire));
    group.setSection(0, section);
    try std.testing.expect(!section.isSelected());
    group.setSelected(0);
    try std.testing.expect(section.isSelected());

    var selection: ?*anyopaque = null;
    try std.testing.expectEqual(
        com.S_OK,
        SettingsSectionProvider.QueryInterface(
            &section.base,
            &com.IID_ISelectionItemProvider,
            &selection,
        ),
    );
    try std.testing.expect(selection != null);
    _ = SettingsSectionProvider.SelectionRelease(@ptrCast(@alignCast(selection.?)));

    group.detach();
    section.detach();
    try std.testing.expectEqual(@as(u32, 0), SettingsSectionProvider.Release(&section.base));
    try std.testing.expectEqual(@as(u32, 1), group.refcount.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), SettingsSectionGroupProvider.Release(&group.base));
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

        fn snapshot(ctx: *anyopaque, alloc: std.mem.Allocator) !TerminalSnapshot {
            const d: *TestTerminalStateData = @ptrCast(@alignCast(ctx));
            d.value_calls += 1;
            d.snapshot_calls += 1;

            const document_text = try alloc.dupe(u8, d.value_text);
            errdefer alloc.free(document_text);
            const visible_text = try alloc.dupe(u8, d.visible_value_text);
            return .{
                .document_text = document_text,
                .visible_text = visible_text,
                .visible_range = d.visible_range,
                .caret_offset = d.caret_offset,
                .terminal_selection_range = d.terminal_selection_range,
                .terminal_selection_active_offset = d.terminal_selection_active_offset,
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
        .snapshot = callbacks.snapshot,
        .focused = callbacks.focused,
    };
}
