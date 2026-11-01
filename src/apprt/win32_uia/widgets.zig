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
const object = @import("object.zig");
const constants = @import("constants.zig");
const events = @import("events.zig");
const terminal_text = @import("text.zig");

/// Private tab-button message. It carries a stable tab ID, never a pointer.
pub const tab_close_message: u32 = 0x8000 + 16;

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
extern "user32" fn GetWindowRect(hWnd: com.HWND, lpRect: *RECT) callconv(.winapi) com.BOOL;
extern "user32" fn SetFocus(hWnd: com.HWND) callconv(.winapi) ?com.HWND;
extern "user32" fn GetDlgCtrlID(hWnd: com.HWND) callconv(.winapi) i32;
extern "user32" fn GetParent(hWnd: com.HWND) callconv(.winapi) ?com.HWND;
extern "user32" fn IsWindow(hWnd: com.HWND) callconv(.winapi) com.BOOL;
extern "user32" fn IsWindowEnabled(hWnd: com.HWND) callconv(.winapi) com.BOOL;
extern "user32" fn IsWindowVisible(hWnd: com.HWND) callconv(.winapi) com.BOOL;
extern "user32" fn GetWindowLongPtrW(hWnd: com.HWND, nIndex: i32) callconv(.winapi) isize;
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
/// provider from `Host` (which lives in `win32/host.zig` and would pull a
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
    invoke_row: ?*const fn (ctx: *anyopaque, index: usize) void = null,
    geometry: ?*const fn (ctx: *anyopaque) ?PaletteListGeometry = null,
    /// Optional screen-space bounds for widgets whose rows are not arranged
    /// as one contiguous vertical list (for example, terminal hint chips).
    row_bounds: ?*const fn (ctx: *anyopaque, index: usize) ?PaletteListRowBounds = null,
    /// The list's `HelpText`: how to use it, read when it takes the focus.
    help_text: []const u8 = "",
    /// A row's `HelpText`, written into `buf` (what the row documents).
    row_help: ?*const fn (ctx: *anyopaque, index: usize, buf: []u8) []const u8 = null,
    /// The keyboard focus is on the selected row while the list has it, as in
    /// a native list box: the fragment root answers it for `GetFocus`, and a
    /// selection change while the list is focused is a focus change too. For
    /// a list that takes the keyboard focus itself; a palette whose focus
    /// stays in its query field leaves this off.
    focus_selected_row: bool = false,
    use_com_threading: bool = false,
};

pub const PaletteListGeometry = struct {
    bounds: com.UiaRect,
    first_visible: usize,
    visible_count: usize,
    row_height: f64,
};

pub const PaletteListRowBounds = com.UiaRect;

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
    scroll_range: ?*const fn (*anyopaque, ScrollRequest) anyerror!void = null,
    current_viewport: ?*const fn (*anyopaque) anyerror!?TerminalViewportGeometry = null,
};

/// Pointer-free request. The UI thread validates the frozen document token
/// under the renderer lock before aligning this absolute document row.
pub const ScrollRequest = struct {
    token: u64,
    document_window: terminal_text.DocumentWindow = .{},
    absolute_row: usize,
    align_to_top: bool,
};

pub const TerminalSnapshot = struct {
    document_text: []u8,
    visible_range: terminal_text.OffsetRange,
    caret_offset: usize = 0,
    selection_range: terminal_text.OffsetRange = .{ .start = 0, .end = 0 },
    terminal_selection_range: ?terminal_text.OffsetRange = null,
    terminal_selection_active_offset: ?usize = null,
    geometry: ?TerminalRangeGeometry = null,

    /// Requires the UTF-8 range normalized by TerminalProvider.terminalSnapshot.
    pub fn visibleText(self: *const TerminalSnapshot) []const u8 {
        return self.document_text[self.visible_range.start..self.visible_range.end];
    }
};

pub const TerminalRangeGeometry = struct {
    scroll_token: ?u64 = null,
    viewport_y: usize = 0,
    document_window: terminal_text.DocumentWindow = .{},
    row_numbering: ?terminal_text.RowNumbering = null,
    cell_for_byte: []terminal_text.TerminalCellPosition,
    viewport_rows: u32,
    viewport_columns: u32,
    cell_width: f64,
    cell_height: f64,
    origin_x: f64,
    origin_y: f64,
};

/// Compact live geometry; querying it never copies the frozen document/map.
pub const TerminalViewportGeometry = struct {
    row_numbering: terminal_text.RowNumbering,
    viewport_y: usize,
    cell_width: f64,
    cell_height: f64,
    origin_x: f64,
    origin_y: f64,
};

pub const PaletteListProvider = struct {
    const Object = object.ComObject(PaletteListProvider, query, object.destroyOnLastRelease(PaletteListProvider));

    fn query(self: *PaletteListProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
        } else if (iidEqual(iid, &com.IID_IRawElementProviderFragmentRoot)) {
            out.* = @ptrCast(&self.fragment_root);
        } else if (iidEqual(iid, &com.IID_IRawElementProviderFragment)) {
            out.* = @ptrCast(&self.fragment);
        } else if (iidEqual(iid, &com.IID_ISelectionProvider)) {
            out.* = @ptrCast(&self.selection_iface);
        } else return com.E_NOINTERFACE;
        _ = self.refcount.fetchAdd(1, .monotonic);
        return com.S_OK;
    }

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
        if (self.focusOnRows()) events.raiseFocusChanged(&row.base);
    }

    /// Whether the keyboard focus is on the selected row now
    /// (`PaletteListState.focus_selected_row`).
    fn focusOnRows(self: *const PaletteListProvider) bool {
        if (!self.state.focus_selected_row) return false;
        const callback = self.state.focused orelse return false;
        return callback(self.state.ctx);
    }

    /// The list took the keyboard focus: with the focus on its rows, the
    /// selected row is what a reader announces.
    pub fn raiseFocusOnSelectedRow(self: *PaletteListProvider) void {
        if (com.UiaClientsAreListening() == 0 or !self.focusOnRows()) return;
        const index = self.selectedIndex() orelse return events.raiseFocusChanged(&self.base);
        const row = self.createRow(index) orelse return;
        defer _ = PaletteRowProvider.Release(&row.base);
        events.raiseFocusChanged(&row.base);
    }

    /// Publish removal while the provider and its row fragments are still
    /// queryable, before the owner detaches and destroys the widget HWND.
    pub fn raiseTeardown(self: *PaletteListProvider) void {
        if (!self.isAvailable()) return;
        events.raiseSelectionInvalidated(&self.base);
        events.raiseStructureChanged(&self.base, .children_bulk_removed, null);
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
        if (!self.isAvailable() or index >= self.rowCount()) return null;
        if (self.state.row_bounds) |callback| {
            const value = callback(self.state.ctx, index) orelse return null;
            if (!validPaletteBounds(value)) return null;
            return value;
        }

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

    fn listBounds(self: *const PaletteListProvider) ?com.UiaRect {
        if (self.geometry()) |value| return value.bounds;

        var result: ?com.UiaRect = null;
        for (0..self.rowCount()) |index| {
            const row = self.rowBounds(index) orelse continue;
            if (result) |*bounds| {
                const right = @max(bounds.left + bounds.width, row.left + row.width);
                const bottom = @max(bounds.top + bounds.height, row.top + row.height);
                bounds.left = @min(bounds.left, row.left);
                bounds.top = @min(bounds.top, row.top);
                bounds.width = right - bounds.left;
                bounds.height = bottom - bounds.top;
            } else {
                result = row;
            }
        }
        return result;
    }

    fn rowEnabled(self: *const PaletteListProvider, index: usize) bool {
        if (index >= self.rowCount()) return false;
        const callback = self.state.row_enabled orelse return true;
        return callback(self.state.ctx, index);
    }

    pub const QueryInterface = Object.Interface("base").QueryInterface;

    pub const AddRef = Object.Interface("base").AddRef;

    pub const Release = Object.Interface("base").Release;

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

    const SelectionQueryInterface = Object.Interface("selection_iface").QueryInterface;

    const SelectionAddRef = Object.Interface("selection_iface").AddRef;

    const SelectionRelease = Object.Interface("selection_iface").Release;

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
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;

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
            constants.UIA_FrameworkIdPropertyId => return object.frameworkId(out),
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
                // With the focus on its rows, the selected row has it.
                out.* = com.VARIANT.fromBool(focused and !(self.state.focus_selected_row and self.selectedIndex() != null));
            },
            constants.UIA_HelpTextPropertyId => if (self.state.help_text.len != 0) {
                const bstr = allocBstrFromUtf8(self.alloc, self.state.help_text) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
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
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        }
        return object.hostProvider(self.hwnd, out);
    }

    const FragmentQueryInterface = Object.Interface("fragment").QueryInterface;

    const FragmentAddRef = Object.Interface("fragment").AddRef;

    const FragmentRelease = Object.Interface("fragment").Release;

    const FragmentRootQueryInterface = Object.Interface("fragment_root").QueryInterface;

    const FragmentRootAddRef = Object.Interface("fragment_root").AddRef;

    const FragmentRootRelease = Object.Interface("fragment_root").Release;

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
        if (self.listBounds()) |value| out.* = value;
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
        if (self.state.row_bounds != null) {
            for (0..self.rowCount()) |index| {
                const bounds = self.rowBounds(index) orelse continue;
                if (x < bounds.left or x >= bounds.left + bounds.width or
                    y < bounds.top or y >= bounds.top + bounds.height)
                {
                    continue;
                }
                const row = self.createRow(index) orelse return com.S_OK;
                out.* = &row.fragment;
                return com.S_OK;
            }
            return com.S_OK;
        }

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
        if (!self.isAvailable()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const focused = if (self.state.focused) |callback|
            callback(self.state.ctx)
        else
            false;
        if (!focused) return com.S_OK;
        if (self.state.focus_selected_row) if (self.selectedIndex()) |index| {
            const row = self.createRow(index) orelse return com.E_OUTOFMEMORY;
            out.* = &row.fragment;
            return com.S_OK;
        };
        _ = FragmentAddRef(&self.fragment);
        out.* = &self.fragment;
        return com.S_OK;
    }
};

fn validPaletteBounds(bounds: com.UiaRect) bool {
    return std.math.isFinite(bounds.left) and
        std.math.isFinite(bounds.top) and
        std.math.isFinite(bounds.width) and
        std.math.isFinite(bounds.height) and
        bounds.width > 0 and
        bounds.height > 0;
}

/// The most of a row's help text a client gets (`PaletteListState.row_help`).
const row_help_capacity = 16 * 1024;
/// `SetFocus` the window: inside `PaletteRowProvider` the name is its method.
const focusWindow = SetFocus;

const PaletteRowProvider = struct {
    const Object = object.ComObject(PaletteRowProvider, query, release);

    base: com.IRawElementProviderSimple,
    fragment: com.IRawElementProviderFragment,
    selection_item: com.ISelectionItemProvider,
    invoke_item: com.IInvokeProvider,
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
    const invoke_vtbl: com.IInvokeProviderVtbl = .{
        .QueryInterface = InvokeQueryInterface,
        .AddRef = InvokeAddRef,
        .Release = InvokeRelease,
        .Invoke = Invoke,
    };

    fn create(alloc: std.mem.Allocator, parent: *PaletteListProvider, index: usize, id: u64) !*PaletteRowProvider {
        const self = try alloc.create(PaletteRowProvider);
        _ = PaletteListProvider.AddRef(&parent.base);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .fragment = .{ .vtbl = &fragment_vtbl },
            .selection_item = .{ .vtbl = &selection_vtbl },
            .invoke_item = .{ .vtbl = &invoke_vtbl },
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
    fn fromInvoke(p: *com.IInvokeProvider) *PaletteRowProvider {
        return @fieldParentPtr("invoke_item", p);
    }
    /// Whether the row's item is still in the list, found by its id: the
    /// RuntimeId names the item, so a row the list moved (a rebuild sorted
    /// another item in before it, a search changed what is shown) is found
    /// where it is now and stays that item, and one whose item is gone is
    /// not available. `index` follows it. Lists with positional ids behave as
    /// before: their id at another index is another item.
    fn available(self: *PaletteRowProvider) bool {
        if (!self.parent.isAvailable()) return false;
        const count = self.parent.rowCount();
        if (self.index < count and self.parent.rowId(self.index) == self.id) return true;
        for (0..count) |index| if (self.parent.rowId(index) == self.id) {
            self.index = index;
            return true;
        };
        return false;
    }

    fn query(self: *PaletteRowProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or iidEqual(iid, &com.IID_IRawElementProviderSimple)) out.* = @ptrCast(&self.base) else if (iidEqual(iid, &com.IID_IRawElementProviderFragment)) out.* = @ptrCast(&self.fragment) else if (iidEqual(iid, &com.IID_ISelectionItemProvider)) out.* = @ptrCast(&self.selection_item) else if (self.parent.state.invoke_row != null and iidEqual(iid, &com.IID_IInvokeProvider)) out.* = @ptrCast(&self.invoke_item) else return com.E_NOINTERFACE;
        _ = self.refcount.fetchAdd(1, .monotonic);
        return com.S_OK;
    }
    const QueryInterface = Object.Interface("base").QueryInterface;
    const FragmentQueryInterface = Object.Interface("fragment").QueryInterface;
    const SelectionQueryInterface = Object.Interface("selection_item").QueryInterface;
    const InvokeQueryInterface = Object.Interface("invoke_item").QueryInterface;
    fn addRef(self: *PaletteRowProvider) u32 {
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }
    const AddRef = Object.Interface("base").AddRef;
    const FragmentAddRef = Object.Interface("fragment").AddRef;
    const SelectionAddRef = Object.Interface("selection_item").AddRef;
    const InvokeAddRef = Object.Interface("invoke_item").AddRef;
    fn release(self: *PaletteRowProvider) u32 {
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            _ = PaletteListProvider.Release(&self.parent.base);
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }
    pub const Release = Object.Interface("base").Release;
    const FragmentRelease = Object.Interface("fragment").Release;
    const SelectionRelease = Object.Interface("selection_item").Release;
    const InvokeRelease = Object.Interface("invoke_item").Release;
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
        } else if (pattern == constants.UIA_InvokePatternId and self.parent.state.invoke_row != null) {
            out.* = @ptrCast(&self.invoke_item);
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
            constants.UIA_HelpTextPropertyId => if (self.parent.state.row_help) |callback| {
                var buf: [row_help_capacity]u8 = undefined;
                const bstr = allocBstrFromUtf8(self.alloc, callback(self.parent.state.ctx, self.index, &buf)) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_HasKeyboardFocusPropertyId => out.* = com.VARIANT.fromBool(self.parent.focusOnRows() and self.parent.selectedIndex() == self.index),
            constants.UIA_IsKeyboardFocusablePropertyId => out.* = com.VARIANT.fromBool(self.parent.state.focus_selected_row),
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
        return object.runtimeId(&.{
            com.UiaAppendRuntimeId,
            @bitCast(@as(u32, @truncate(self.id))),
            @bitCast(@as(u32, @truncate(self.id >> 32))),
        }, out);
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
        if (!self.parent.state.focus_selected_row) return com.E_NOTIMPL;
        // The focus is on the selected row: select it and focus the list. A
        // list that did not take the focus (going away, or disabled) says so.
        const hr = self.select();
        if (hr != com.S_OK) return hr;
        _ = focusWindow(self.parent.hwnd);
        return if (hwndHasKeyboardFocus(self.parent.hwnd)) com.S_OK else com.UIA_E_ELEMENTNOTAVAILABLE;
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
    fn Invoke(p: *com.IInvokeProvider) callconv(.winapi) com.HRESULT {
        const self = fromInvoke(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.parent.rowEnabled(self.index)) return com.UIA_E_ELEMENTNOTENABLED;
        const callback = self.parent.state.invoke_row orelse return com.UIA_E_INVALIDOPERATION;
        callback(self.parent.state.ctx, self.index);
        return com.S_OK;
    }
};

pub const settings_section_count = 9;

/// Stable provider for native STATIC controls that this custom settings
/// window otherwise exposes as generic Panes through the system bridge.
pub const SettingsControlProvider = struct {
    const Object = object.ComObject(SettingsControlProvider, query, release);

    fn query(self: *SettingsControlProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
        } else if (self.role.hasValue() and iidEqual(iid, &com.IID_IValueProvider)) {
            out.* = @ptrCast(&self.value_iface);
        } else if (self.role == .button and iidEqual(iid, &com.IID_IInvokeProvider)) {
            out.* = @ptrCast(&self.invoke_iface);
        } else if (self.role == .check_box and iidEqual(iid, &com.IID_IToggleProvider)) {
            out.* = @ptrCast(&self.toggle_iface);
        } else if (self.role == .combo_box and iidEqual(iid, &com.IID_IExpandCollapseProvider)) {
            out.* = @ptrCast(&self.expand_iface);
        } else return com.E_NOINTERFACE;
        _ = AddRef(&self.base);
        return com.S_OK;
    }

    fn release(self: *SettingsControlProvider) u32 {
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            if (self.labeled_by) |label| _ = label.vtbl.Release(label);
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }

    pub const Role = enum {
        text,
        /// Text that a reader speaks when it changes, such as the status line
        /// and the close prompt: a non-live element is spoken only if
        /// something focuses it.
        live_text,
        edit,
        combo_box,
        check_box,
        button,
        /// A window that only clips and scrolls its children (the Settings
        /// form viewport). It stays out of the control and content views,
        /// so its children read as children of the window, as they did
        /// before the viewport existed.
        layout_pane,

        /// Edits and combo boxes expose `IValueProvider`.
        fn hasValue(self: Role) bool {
            return self == .edit or self == .combo_box;
        }
    };

    base: com.IRawElementProviderSimple,
    value_iface: com.IValueProvider,
    invoke_iface: com.IInvokeProvider,
    toggle_iface: com.IToggleProvider,
    expand_iface: com.IExpandCollapseProvider,
    // Only read/written by the HWND's thread, through syncNativeState.
    last_toggle: i32 = 0,
    last_expanded: i32 = 0,
    last_selection: isize = -1,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    role: Role,
    name: ?[]const u8,
    /// Static descriptor text; assigned before publishing the provider.
    help_text: []const u8 = "",
    /// The element that names this one (`UIA_LabeledByPropertyId`). Holds
    /// a reference, released with this provider.
    labeled_by: ?*com.IRawElementProviderSimple = null,
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),
    viewport_fully_clipped: std.atomic.Value(bool),
    /// The field holds a value Settings will not accept
    /// (`UIA_IsDataValidForFormPropertyId`).
    data_invalid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The field's value differs from its default, which the form marks
    /// beside it; said as the field's `ItemStatus`, so the mark is not only
    /// drawn.
    changed_from_default: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const changed_from_default_status = "Changed from the default";

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

    const ToggleInterface = Object.Interface("toggle_iface");
    const ExpandInterface = Object.Interface("expand_iface");
    const toggle_vtbl: com.IToggleProviderVtbl = .{
        .QueryInterface = ToggleInterface.QueryInterface,
        .AddRef = ToggleInterface.AddRef,
        .Release = ToggleInterface.Release,
        .Toggle = Toggle,
        .get_ToggleState = GetToggleState,
    };
    const expand_vtbl: com.IExpandCollapseProviderVtbl = .{
        .QueryInterface = ExpandInterface.QueryInterface,
        .AddRef = ExpandInterface.AddRef,
        .Release = ExpandInterface.Release,
        .Expand = Expand,
        .Collapse = Collapse,
        .get_ExpandCollapseState = GetExpandedState,
    };

    /// Pointer-free requests, marshalled to settingsControlProc. In particular,
    /// a Toggle is one UI-thread operation, not a racy read/set/notify sequence.
    pub const action_message: u32 = 0x8000 + 0x10C;
    pub const action_success: isize = 1;
    pub const Action = enum(usize) { toggle, select, expand, collapse };
    pub const SelectionSync = enum { observe, native_notification, explicit_selection };

    const BM_GETCHECK: u32 = 0x00F0;
    const BM_SETCHECK: u32 = 0x00F1;
    const CB_GETCOUNT: u32 = 0x0146;
    const CB_GETCURSEL: u32 = 0x0147;
    const CB_SETCURSEL: u32 = 0x014E;
    const CB_SHOWDROPDOWN: u32 = 0x014F;
    const CB_GETDROPPEDSTATE: u32 = 0x0157;
    const CB_FINDSTRINGEXACT: u32 = 0x0158;
    const BN_CLICKED: u16 = 0;
    const CBN_SELCHANGE: u16 = 1;

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
            .toggle_iface = .{ .vtbl = &toggle_vtbl },
            .expand_iface = .{ .vtbl = &expand_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .role = role,
            .name = name,
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
            .viewport_fully_clipped = std.atomic.Value(bool).init(false),
        };
        if (role == .check_box) self.last_toggle = self.toggleState();
        if (role == .combo_box) self.last_selection = SendMessageW(hwnd, CB_GETCURSEL, 0, 0);
        return self;
    }

    pub fn detach(self: *SettingsControlProvider) void {
        self.detached.store(true, .release);
    }

    pub fn setLabeledBy(self: *SettingsControlProvider, label: *com.IRawElementProviderSimple) void {
        _ = label.vtbl.AddRef(label);
        if (self.labeled_by) |old| _ = old.vtbl.Release(old);
        self.labeled_by = label;
    }

    /// An `ES_READONLY` EDIT, such as the confirm preview pane.
    fn readOnly(self: *const SettingsControlProvider) bool {
        const gwl_style = -16;
        const es_readonly = 0x0800;
        return self.role == .edit and (GetWindowLongPtrW(self.hwnd, gwl_style) & es_readonly) != 0;
    }

    pub fn setViewportFullyClipped(self: *SettingsControlProvider, fully_clipped: bool) void {
        self.viewport_fully_clipped.store(fully_clipped, .release);
    }

    pub fn raiseFocusChanged(self: *SettingsControlProvider) void {
        if (!self.available()) return;
        events.raiseFocusChanged(&self.base);
    }

    /// Announce new text in a `live_text` element. Call it once the element is
    /// on screen: a reader drops a live region that reports `IsOffscreen`.
    pub fn raiseLiveRegionChanged(self: *SettingsControlProvider) void {
        if (!self.available() or self.role != .live_text) return;
        events.raiseNameChanged(&self.base);
        events.raiseLiveRegionChanged(&self.base);
    }

    /// Mark the field as holding a value Settings will not accept, or clear it.
    pub fn setDataInvalid(self: *SettingsControlProvider, invalid: bool) void {
        if (self.data_invalid.swap(invalid, .acq_rel) == invalid or !self.available()) return;
        events.raisePropertyChanged(
            &self.base,
            constants.UIA_IsDataValidForFormPropertyId,
            com.VARIANT.fromBool(invalid),
            com.VARIANT.fromBool(!invalid),
        );
    }

    /// Say whether the field differs from its default; a change is announced
    /// as a new `ItemStatus`.
    pub fn setChangedFromDefault(self: *SettingsControlProvider, changed: bool) void {
        if (self.changed_from_default.swap(changed, .acq_rel) == changed or !self.available()) return;
        events.raiseCurrentStringPropertyChanged(&self.base, constants.UIA_ItemStatusPropertyId);
    }

    fn isField(self: *const SettingsControlProvider) bool {
        return self.role == .edit or self.role == .combo_box or self.role == .check_box;
    }

    fn isText(self: *const SettingsControlProvider) bool {
        return self.role == .text or self.role == .live_text;
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

    const QueryInterface = Object.Interface("base").QueryInterface;

    const ValueQueryInterface = Object.Interface("value_iface").QueryInterface;

    const InvokeQueryInterface = Object.Interface("invoke_iface").QueryInterface;

    const AddRef = Object.Interface("base").AddRef;

    const ValueAddRef = Object.Interface("value_iface").AddRef;

    const InvokeAddRef = Object.Interface("invoke_iface").AddRef;

    pub const Release = Object.Interface("base").Release;

    const ValueRelease = Object.Interface("value_iface").Release;

    const InvokeRelease = Object.Interface("invoke_iface").Release;

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
        if (self.isText()) return com.S_OK;
        const pattern: ?*com.IUnknown = if (self.role.hasValue() and pattern_id == constants.UIA_ValuePatternId)
            @ptrCast(&self.value_iface)
        else if (self.role == .button and pattern_id == constants.UIA_InvokePatternId)
            @ptrCast(&self.invoke_iface)
        else if (self.role == .check_box and pattern_id == constants.UIA_TogglePatternId)
            @ptrCast(&self.toggle_iface)
        else if (self.role == .combo_box and pattern_id == constants.UIA_ExpandCollapsePatternId)
            @ptrCast(&self.expand_iface)
        else
            null;
        if (pattern) |provider| {
            out.* = provider;
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
                .text, .live_text => constants.UIA_TextControlTypeId,
                .edit => constants.UIA_EditControlTypeId,
                .combo_box => constants.UIA_ComboBoxControlTypeId,
                .check_box => constants.UIA_CheckBoxControlTypeId,
                .button => constants.UIA_ButtonControlTypeId,
                .layout_pane => constants.UIA_PaneControlTypeId,
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
            constants.UIA_HelpTextPropertyId => if (self.help_text.len != 0) {
                const bstr = allocBstrFromUtf8(self.alloc, self.help_text) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_ItemStatusPropertyId => if (self.isField()) {
                const status = if (self.changed_from_default.load(.acquire)) changed_from_default_status else "";
                const bstr = allocBstrFromUtf8(self.alloc, status) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_ValueValuePropertyId => if (self.role.hasValue()) {
                const value = self.allocValueBstr() orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(value);
            },
            constants.UIA_ValueIsReadOnlyPropertyId => if (self.role.hasValue()) {
                out.* = com.VARIANT.fromBool(self.readOnly());
            },
            constants.UIA_ToggleToggleStatePropertyId => if (self.role == .check_box) {
                out.* = com.VARIANT.fromI4(self.toggleState());
            },
            constants.UIA_ExpandCollapseExpandCollapseStatePropertyId => if (self.role == .combo_box) {
                out.* = com.VARIANT.fromI4(self.expandCollapseState());
            },
            constants.UIA_LabeledByPropertyId => if (self.labeled_by) |label| {
                _ = label.vtbl.AddRef(label);
                out.* = com.VARIANT.fromUnknown(@ptrCast(label));
            },
            constants.UIA_FrameworkIdPropertyId => return object.frameworkId(out),
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            => out.* = com.VARIANT.fromBool(self.role != .layout_pane),
            constants.UIA_IsEnabledPropertyId => out.* = com.VARIANT.fromBool(IsWindowEnabled(self.hwnd) != 0),
            constants.UIA_IsKeyboardFocusablePropertyId => out.* = com.VARIANT.fromBool(
                !self.isText() and self.role != .layout_pane,
            ),
            constants.UIA_HasKeyboardFocusPropertyId => out.* = com.VARIANT.fromBool(
                !self.isText() and self.role != .layout_pane and hwndHasKeyboardFocus(self.hwnd),
            ),
            constants.UIA_IsOffscreenPropertyId => out.* = com.VARIANT.fromBool(settingsControlIsOffscreen(
                IsWindowVisible(self.hwnd),
                self.viewport_fully_clipped.load(.acquire),
            )),
            constants.UIA_LiveSettingPropertyId => if (self.role == .live_text) {
                out.* = com.VARIANT.fromI4(constants.LiveSetting_Polite);
            },
            // Said for every field, not only the invalid one: a property a
            // provider leaves out reads as FALSE, which would make every field
            // that was never touched look invalid.
            constants.UIA_IsDataValidForFormPropertyId => switch (self.role) {
                .edit, .combo_box, .check_box => out.* = com.VARIANT.fromBool(!self.data_invalid.load(.acquire)),
                else => {},
            },
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
        if (!role.hasValue()) return com.UIA_E_INVALIDOPERATION;
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
        value_arg: ?[*:0]const u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(p);
        const precondition = setValuePrecondition(
            self.available(),
            self.role,
            IsWindowEnabled(self.hwnd) != 0,
        );
        if (precondition != com.S_OK) return precondition;
        if (self.readOnly()) return com.UIA_E_INVALIDOPERATION;
        const value = value_arg orelse return com.E_INVALIDARG;
        if (self.role == .combo_box) {
            // Keep the borrowed string alive until the native lookup returns,
            // including same-process cross-thread calls. A timed-out send could
            // return while the control still reads it. The bounded private
            // mutation request carries only the resulting index.
            const index = SendMessageW(self.hwnd, CB_FINDSTRINGEXACT, std.math.maxInt(usize), @bitCast(@intFromPtr(value)));
            if (index < 0) return com.E_INVALIDARG;
            return self.requestAction(.select, index);
        }
        return if (com.SetWindowTextW(self.hwnd, value) != 0) com.S_OK else com.E_INVALIDARG;
    }

    fn GetValue(
        p: *com.IValueProvider,
        out: *com.BSTR,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.role.hasValue()) return com.UIA_E_INVALIDOPERATION;
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
        if (!self.role.hasValue()) return com.UIA_E_INVALIDOPERATION;
        out.* = @intFromBool(self.readOnly());
        return com.S_OK;
    }

    fn requestAction(self: *SettingsControlProvider, action: Action, index: isize) com.HRESULT {
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        var result: usize = 0;
        if (SendMessageTimeoutW(self.hwnd, action_message, @intFromEnum(action), index, SMTO_BLOCK | SMTO_ABORTIFHUNG, settings_selection_timeout_ms, &result) == 0)
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (result == action_success) return com.S_OK;
        if (result == 0) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return @bitCast(@as(u32, @truncate(result)));
    }

    /// Called only by the native control's owning thread. Route changes through
    /// the existing BN_CLICKED/CBN_SELCHANGE handlers, including draft tracking,
    /// preview and Save; never write Settings' transaction from a COM thread.
    pub fn handleAction(self: *SettingsControlProvider, raw_action: usize, index: isize) com.HRESULT {
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (IsWindowEnabled(self.hwnd) == 0) return com.UIA_E_ELEMENTNOTENABLED;
        const action = std.meta.intToEnum(Action, raw_action) catch return com.E_INVALIDARG;
        const parent = GetParent(self.hwnd) orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        switch (action) {
            .toggle => {
                if (self.role != .check_box) return com.UIA_E_INVALIDOPERATION;
                const checked = SendMessageW(self.hwnd, BM_GETCHECK, 0, 0) != 0;
                _ = SendMessageW(self.hwnd, BM_SETCHECK, @intFromBool(!checked), 0);
            },
            .select => {
                if (self.role != .combo_box) return com.UIA_E_INVALIDOPERATION;
                if (index < 0 or index >= SendMessageW(self.hwnd, CB_GETCOUNT, 0, 0)) return com.E_INVALIDARG;
                _ = SendMessageW(self.hwnd, CB_SETCURSEL, @intCast(index), 0);
                self.syncNativeState(.explicit_selection);
                return com.S_OK;
            },
            .expand, .collapse => {
                if (self.role != .combo_box) return com.UIA_E_INVALIDOPERATION;
                _ = SendMessageW(self.hwnd, CB_SHOWDROPDOWN, @intFromBool(action == .expand), 0);
                self.syncNativeState(.observe);
                return com.S_OK;
            },
        }
        self.notifyParent(parent, BN_CLICKED);
        self.syncNativeState(.observe);
        return com.S_OK;
    }

    /// Send the parent the WM_COMMAND notification the native control sends.
    fn notifyParent(self: *SettingsControlProvider, parent: com.HWND, code: u16) void {
        const control_id: usize = @intCast(GetDlgCtrlID(self.hwnd));
        _ = SendMessageW(parent, WM_COMMAND, control_id | (@as(usize, code) << 16), @bitCast(@intFromPtr(self.hwnd)));
    }

    fn toggleState(self: *const SettingsControlProvider) i32 {
        return @intCast(SendMessageW(self.hwnd, BM_GETCHECK, 0, 0));
    }

    fn expandCollapseState(self: *const SettingsControlProvider) i32 {
        return @intFromBool(SendMessageW(self.hwnd, CB_GETDROPPEDSTATE, 0, 0) != 0);
    }

    fn Toggle(p: *com.IToggleProvider) callconv(.winapi) com.HRESULT {
        const self: *SettingsControlProvider = @fieldParentPtr("toggle_iface", p);
        return self.requestAction(.toggle, 0);
    }
    fn GetToggleState(p: *com.IToggleProvider, out: *i32) callconv(.winapi) com.HRESULT {
        const self: *SettingsControlProvider = @fieldParentPtr("toggle_iface", p);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = self.toggleState();
        return com.S_OK;
    }
    fn Expand(p: *com.IExpandCollapseProvider) callconv(.winapi) com.HRESULT {
        const self: *SettingsControlProvider = @fieldParentPtr("expand_iface", p);
        return self.requestAction(.expand, 0);
    }
    fn Collapse(p: *com.IExpandCollapseProvider) callconv(.winapi) com.HRESULT {
        const self: *SettingsControlProvider = @fieldParentPtr("expand_iface", p);
        return self.requestAction(.collapse, 0);
    }
    fn GetExpandedState(p: *com.IExpandCollapseProvider, out: *i32) callconv(.winapi) com.HRESULT {
        const self: *SettingsControlProvider = @fieldParentPtr("expand_iface", p);
        out.* = 0;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = self.expandCollapseState();
        return com.S_OK;
    }

    /// The native HWND thread owns this cache. Compare after native mutations
    /// as well as UIA actions, so mouse/keyboard and Discard announce changes.
    pub fn syncNativeState(self: *SettingsControlProvider, selection_sync: SelectionSync) void {
        if (!self.available()) return;
        if (self.role == .check_box) {
            const next = self.toggleState();
            const old = self.last_toggle;
            self.last_toggle = next;
            if (old != next) events.raisePropertyChanged(&self.base, constants.UIA_ToggleToggleStatePropertyId, com.VARIANT.fromI4(old), com.VARIANT.fromI4(next));
        } else if (self.role == .combo_box) {
            const expanded = self.expandCollapseState();
            const old_expanded = self.last_expanded;
            self.last_expanded = expanded;
            if (expanded != old_expanded) events.raisePropertyChanged(&self.base, constants.UIA_ExpandCollapseExpandCollapseStatePropertyId, com.VARIANT.fromI4(old_expanded), com.VARIANT.fromI4(expanded));
            // A list tracks its hovered row before the user chooses it, even
            // during close notifications. Only a committed native notification
            // or explicit selection may consume the selection-cache change.
            if (selection_sync == .observe) return;
            const selected = SendMessageW(self.hwnd, CB_GETCURSEL, 0, 0);
            if (self.last_selection != selected) {
                self.last_selection = selected;
                // The stock popup's SelectionItem proxy can set a combo's
                // index without CBN_SELCHANGE. Keep its native state and the
                // Settings draft together, using the same parent handler.
                // Update the cache first: the handler may refresh controls.
                if (selection_sync == .explicit_selection) {
                    if (GetParent(self.hwnd)) |parent| self.notifyParent(parent, CBN_SELCHANGE);
                }
                events.raiseCurrentStringPropertyChanged(&self.base, constants.UIA_ValueValuePropertyId);
            }
        }
    }

    /// A combo's rows were rebuilt and its selected row kept its index but
    /// not its text (Settings' Default profile dropdown relabels a profile):
    /// announce the new Value. `syncNativeState` compares indexes only.
    pub fn valueTextChanged(self: *SettingsControlProvider) void {
        if (!self.available() or self.role != .combo_box) return;
        events.raiseCurrentStringPropertyChanged(&self.base, constants.UIA_ValueValuePropertyId);
    }

    fn getHostRawElementProvider(
        p: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return object.hostProvider(self.hwnd, out);
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
    const Object = object.ComObject(SettingsSectionGroupProvider, query, object.destroyOnLastRelease(SettingsSectionGroupProvider));

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

    fn query(
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

    const QueryInterface = Object.Interface("base").QueryInterface;

    const AddRef = Object.Interface("base").AddRef;

    pub const Release = Object.Interface("base").Release;

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
            constants.UIA_FrameworkIdPropertyId => return object.frameworkId(out),
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
        return object.hostProvider(self.hwnd, out);
    }

    const SelectionQueryInterface = Object.Interface("selection_iface").QueryInterface;

    const SelectionAddRef = Object.Interface("selection_iface").AddRef;

    const SelectionRelease = Object.Interface("selection_iface").Release;

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

/// What a Settings section holds that the user should know about without
/// opening it, in the order of urgency. Reported as the rail button's
/// `ItemStatus`, so the cue is not the dot on the button alone.
pub const SettingsSectionMarker = enum(u8) {
    none,
    unsaved,
    invalid,

    pub fn itemStatus(self: SettingsSectionMarker) []const u8 {
        return switch (self) {
            .none => "",
            .unsaved => "Has unsaved changes",
            .invalid => "Has an invalid value",
        };
    }
};

/// Explicit provider for the settings window's native section radio buttons.
/// The system UIA bridge reports these push-like BUTTON HWNDs as generic Panes,
/// so Narrator otherwise loses both their radio role and selection semantics.
pub const SettingsSectionProvider = struct {
    const Object = object.ComObject(SettingsSectionProvider, query, release);

    fn release(self: *SettingsSectionProvider) u32 {
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            _ = SettingsSectionGroupProvider.Release(&self.container.base);
            self.alloc.destroy(self);
            return 0;
        }
        return previous - 1;
    }

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
    marker: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(SettingsSectionMarker.none)),
    /// How many rows the Settings search found on this section's page, or
    /// `no_search` while nothing is searched for.
    search_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(no_search),

    const no_search: i32 = -1;

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

    pub fn markerState(self: *const SettingsSectionProvider) SettingsSectionMarker {
        return @enumFromInt(self.marker.load(.acquire));
    }

    /// Say what the section holds; a change is announced as a new `ItemStatus`.
    pub fn setMarker(self: *SettingsSectionProvider, marker: SettingsSectionMarker) void {
        if (self.marker.swap(@intFromEnum(marker), .acq_rel) == @intFromEnum(marker)) return;
        if (!self.available()) return;
        events.raiseCurrentStringPropertyChanged(&self.base, constants.UIA_ItemStatusPropertyId);
    }

    /// Say how many settings the search found on the section's page, or with
    /// null that nothing is searched for; also part of `ItemStatus`.
    pub fn setSearchCount(self: *SettingsSectionProvider, count: ?u16) void {
        const value: i32 = if (count) |found| found else no_search;
        if (self.search_count.swap(value, .acq_rel) == value) return;
        if (!self.available()) return;
        events.raiseCurrentStringPropertyChanged(&self.base, constants.UIA_ItemStatusPropertyId);
    }

    /// `ItemStatus`: what the section holds, then what the search found on it.
    pub fn itemStatus(self: *const SettingsSectionProvider, buf: []u8) []const u8 {
        const marker = self.markerState().itemStatus();
        const count = self.search_count.load(.acquire);
        if (count == no_search) return marker;
        const separator: []const u8 = if (marker.len == 0) "" else ", ";
        return switch (count) {
            0 => std.fmt.bufPrint(buf, "{s}{s}no settings found", .{ marker, separator }),
            1 => std.fmt.bufPrint(buf, "{s}{s}1 setting found", .{ marker, separator }),
            else => std.fmt.bufPrint(buf, "{s}{s}{d} settings found", .{ marker, separator, count }),
        } catch marker;
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

    fn query(
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

    const QueryInterface = Object.Interface("base").QueryInterface;

    const AddRef = Object.Interface("base").AddRef;

    pub const Release = Object.Interface("base").Release;

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
            constants.UIA_ItemStatusPropertyId => {
                var status_buf: [96]u8 = undefined;
                const bstr = allocBstrFromUtf8(self.alloc, self.itemStatus(&status_buf)) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_FrameworkIdPropertyId => return object.frameworkId(out),
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
        return object.hostProvider(self.hwnd, out);
    }

    const SelectionQueryInterface = Object.Interface("selection_iface").QueryInterface;

    const SelectionAddRef = Object.Interface("selection_iface").AddRef;

    const SelectionRelease = Object.Interface("selection_iface").Release;

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
        tooltip,
    };

    ctx: *anyopaque,
    role: Role,
    tag: usize = 0,
    name: *const fn (*anyopaque, usize, []u8) []const u8,
    /// The element's status, such as what a tab's program is waiting for.
    /// Reported as `ItemStatus`; empty when there is none.
    item_status: ?*const fn (*anyopaque, usize, []u8) []const u8 = null,
    selected: ?*const fn (*anyopaque, usize) bool = null,
    selected_provider: ?*const fn (*anyopaque) ?*ChromeControlProvider = null,
    selection_container: ?*const fn (*anyopaque) ?*ChromeControlProvider = null,
    close_bounds: ?*const fn (*anyopaque, usize) ?com.UiaRect = null,
    close_invoke: ?*const fn (*anyopaque, usize) bool = null,
    toggled: ?*const fn (*anyopaque, usize) bool = null,
    range_value: ?*const fn (*anyopaque) ChromeRangeValue = null,
    /// Overrides the role's default keyboard focusability, for a control
    /// that real Win32 focus reaches although its role is not interactive
    /// (or the reverse): `IsKeyboardFocusable` must not contradict the
    /// focus-changed event a reader just received.
    keyboard_focusable: ?bool = null,
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
    const Object = object.ComObject(ChromeControlProvider, query, object.destroyOnLastRelease(ChromeControlProvider));

    fn query(self: *ChromeControlProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
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
        } else if (self.state.role == .tab_item and iidEqual(iid, &com.IID_IRawElementProviderFragment)) {
            out.* = @ptrCast(&self.fragment);
        } else if (self.state.role == .tab_item and iidEqual(iid, &com.IID_IRawElementProviderFragmentRoot)) {
            out.* = @ptrCast(&self.fragment_root);
        } else return com.E_NOINTERFACE;
        _ = AddRef(&self.base);
        return com.S_OK;
    }

    base: com.IRawElementProviderSimple,
    invoke_iface: com.IInvokeProvider,
    toggle_iface: com.IToggleProvider,
    range_iface: com.IRangeValueProvider,
    selection_iface: com.ISelectionProvider,
    selection_item_iface: com.ISelectionItemProvider,
    fragment: com.IRawElementProviderFragment,
    fragment_root: com.IRawElementProviderFragmentRoot,
    close_child_present: bool = false,
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
    const fragment_vtbl: com.IRawElementProviderFragmentVtbl = .{
        .QueryInterface = Object.Interface("fragment").QueryInterface,
        .AddRef = Object.Interface("fragment").AddRef,
        .Release = Object.Interface("fragment").Release,
        .Navigate = TabNavigate,
        .GetRuntimeId = TabRuntimeId,
        .get_BoundingRectangle = TabBounds,
        .GetEmbeddedFragmentRoots = TabEmbeddedRoots,
        .SetFocus = TabSetFocus,
        .get_FragmentRoot = TabFragmentRoot,
    };
    const fragment_root_vtbl: com.IRawElementProviderFragmentRootVtbl = .{
        .QueryInterface = Object.Interface("fragment_root").QueryInterface,
        .AddRef = Object.Interface("fragment_root").AddRef,
        .Release = Object.Interface("fragment_root").Release,
        .ElementProviderFromPoint = TabFromPoint,
        .GetFocus = TabFocus,
    };

    fn closeBounds(self: *ChromeControlProvider) ?com.UiaRect {
        if (!self.available()) return null;
        return (self.state.close_bounds orelse return null)(self.state.ctx, self.state.tag);
    }

    pub fn syncCloseChild(self: *ChromeControlProvider) void {
        const present = self.closeBounds() != null;
        if (present == self.close_child_present) return;
        self.close_child_present = present;
        events.raiseStructureChanged(&self.base, .children_invalidated, null);
    }

    fn TabNavigate(p: *com.IRawElementProviderFragment, direction: i32, out: *?*com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        // UIA supplies HWND parent/siblings through the host provider.
        if (direction != com.NavigateDirection_FirstChild and direction != com.NavigateDirection_LastChild) return com.S_OK;
        if (self.closeBounds() == null) return com.S_OK;
        const child = TabCloseProvider.create(self.alloc, self) catch return com.E_OUTOFMEMORY;
        out.* = &child.fragment;
        return com.S_OK;
    }
    fn TabRuntimeId(_: *com.IRawElementProviderFragment, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        out.* = null; // HWND identity is supplied by UIA.
        return com.S_OK;
    }
    fn TabBounds(p: *com.IRawElementProviderFragment, out: *com.UiaRect) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        var rect: RECT = undefined;
        if (GetWindowRect(self.hwnd, &rect) != 0) out.* = .{
            .left = @floatFromInt(rect.left),
            .top = @floatFromInt(rect.top),
            .width = @floatFromInt(rect.right - rect.left),
            .height = @floatFromInt(rect.bottom - rect.top),
        };
        return com.S_OK;
    }
    fn TabEmbeddedRoots(_: *com.IRawElementProviderFragment, out: *?*com.SAFEARRAY) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }
    fn TabSetFocus(p: *com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        _ = SetFocus(self.hwnd);
        return com.S_OK;
    }
    fn TabFragmentRoot(p: *com.IRawElementProviderFragment, out: *?*com.IRawElementProviderFragmentRoot) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        _ = AddRef(&self.base);
        out.* = &self.fragment_root;
        return com.S_OK;
    }
    fn TabFromPoint(p: *com.IRawElementProviderFragmentRoot, x: f64, y: f64, out: *?*com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        const self = fromFragmentRoot(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.closeBounds()) |rect| {
            if (rect.contains(x, y)) return TabNavigate(&self.fragment, com.NavigateDirection_FirstChild, out);
        }
        _ = AddRef(&self.base);
        out.* = &self.fragment;
        return com.S_OK;
    }
    fn TabFocus(p: *com.IRawElementProviderFragmentRoot, out: *?*com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        const self = fromFragmentRoot(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (hwndHasKeyboardFocus(self.hwnd)) {
            _ = AddRef(&self.base);
            out.* = &self.fragment;
        }
        return com.S_OK;
    }

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
            .fragment = .{ .vtbl = &fragment_vtbl },
            .fragment_root = .{ .vtbl = &fragment_root_vtbl },
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
        if (self.closeBounds() != null) {
            const child = TabCloseProvider.create(self.alloc, self) catch return;
            defer _ = TabCloseProvider.Release(&child.base);
            events.raiseNameChanged(&child.base);
        }
    }

    pub fn raiseItemStatusChanged(self: *ChromeControlProvider) void {
        if (!self.available() or self.state.item_status == null) return;
        events.raiseCurrentStringPropertyChanged(&self.base, constants.UIA_ItemStatusPropertyId);
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
    fn fromFragment(p: *com.IRawElementProviderFragment) *ChromeControlProvider {
        return @fieldParentPtr("fragment", p);
    }
    fn fromFragmentRoot(p: *com.IRawElementProviderFragmentRoot) *ChromeControlProvider {
        return @fieldParentPtr("fragment_root", p);
    }

    const QueryInterface = Object.Interface("base").QueryInterface;

    pub const AddRef = Object.Interface("base").AddRef;

    pub const Release = Object.Interface("base").Release;

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
            .live_text, .decorative, .tooltip => null,
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
                .tooltip => constants.UIA_ToolTipControlTypeId,
            }),
            constants.UIA_NamePropertyId => {
                var buf: [512]u8 = undefined;
                const name = self.state.name(self.state.ctx, self.state.tag, &buf);
                const value = allocBstrFromUtf8(self.alloc, name) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(value);
            },
            constants.UIA_ItemStatusPropertyId => if (self.state.item_status) |item_status| {
                var buf: [512]u8 = undefined;
                const status = item_status(self.state.ctx, self.state.tag, &buf);
                const value = allocBstrFromUtf8(self.alloc, status) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(value);
            },
            constants.UIA_FrameworkIdPropertyId => return object.frameworkId(out),
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            => out.* = com.VARIANT.fromBool(self.state.role != .decorative),
            constants.UIA_IsEnabledPropertyId => out.* = com.VARIANT.fromBool(IsWindowEnabled(self.hwnd) != 0),
            constants.UIA_IsOffscreenPropertyId => out.* = com.VARIANT.fromBool(IsWindowVisible(self.hwnd) == 0),
            constants.UIA_IsKeyboardFocusablePropertyId => out.* = com.VARIANT.fromBool(
                // A hidden control is never a focus target: the host's
                // focus-region cycle filters its candidates through
                // `focusableHwnd`, which is exactly `IsWindowVisible`. With
                // `window-show-tab-bar = never` the tab buttons and the
                // [+] / [▾] cluster are hidden but alive, and claiming they
                // are focusable would contradict the focus-changed events a
                // reader actually receives.
                IsWindowVisible(self.hwnd) != 0 and
                    (self.state.keyboard_focusable orelse switch (self.state.role) {
                        .tab_item, .button, .toggle => true,
                        else => false,
                    }),
            ),
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
        return object.hostProvider(self.hwnd, out);
    }

    const InvokeQueryInterface = Object.Interface("invoke_iface").QueryInterface;
    const InvokeAddRef = Object.Interface("invoke_iface").AddRef;
    const InvokeRelease = Object.Interface("invoke_iface").Release;
    fn Invoke(p: *com.IInvokeProvider) callconv(.winapi) com.HRESULT {
        const self = fromInvoke(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.state.role != .button) return com.UIA_E_INVALIDOPERATION;
        return postButtonClicked(self.hwnd);
    }

    const ToggleQueryInterface = Object.Interface("toggle_iface").QueryInterface;
    const ToggleAddRef = Object.Interface("toggle_iface").AddRef;
    const ToggleRelease = Object.Interface("toggle_iface").Release;
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

    const RangeQueryInterface = Object.Interface("range_iface").QueryInterface;
    const RangeAddRef = Object.Interface("range_iface").AddRef;
    const RangeRelease = Object.Interface("range_iface").Release;
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

    const SelectionQueryInterface = Object.Interface("selection_iface").QueryInterface;
    const SelectionAddRef = Object.Interface("selection_iface").AddRef;
    const SelectionRelease = Object.Interface("selection_iface").Release;
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

    const SelectionItemQueryInterface = Object.Interface("selection_item_iface").QueryInterface;
    const SelectionItemAddRef = Object.Interface("selection_item_iface").AddRef;
    const SelectionItemRelease = Object.Interface("selection_item_iface").Release;
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

/// Painted tab close child. Retains the tab provider, whose detachment gates
/// all owner callbacks. Instances share a stable runtime ID, not a cached BSTR.
pub const TabCloseProvider = struct {
    const Object = object.ComObject(TabCloseProvider, query, release);
    const runtime_id_tag: i32 = 0x54434C; // 'TCL'

    base: com.IRawElementProviderSimple,
    fragment: com.IRawElementProviderFragment,
    invoke_iface: com.IInvokeProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    parent: *ChromeControlProvider,

    const simple_vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = QueryInterface,
        .AddRef = AddRef,
        .Release = Release,
        .get_ProviderOptions = get_ProviderOptions,
        .GetPatternProvider = GetPatternProvider,
        .GetPropertyValue = GetPropertyValue,
        .get_HostRawElementProvider = get_HostRawElementProvider,
    };
    const fragment_vtbl: com.IRawElementProviderFragmentVtbl = .{
        .QueryInterface = FragmentQueryInterface,
        .AddRef = FragmentAddRef,
        .Release = FragmentRelease,
        .Navigate = Navigate,
        .GetRuntimeId = GetRuntimeId,
        .get_BoundingRectangle = GetBoundingRectangle,
        .GetEmbeddedFragmentRoots = GetEmbeddedFragmentRoots,
        .SetFocus = TabCloseProvider.SetFocus,
        .get_FragmentRoot = GetFragmentRoot,
    };
    const invoke_vtbl: com.IInvokeProviderVtbl = .{
        .QueryInterface = InvokeQueryInterface,
        .AddRef = InvokeAddRef,
        .Release = InvokeRelease,
        .Invoke = Invoke,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        parent: *ChromeControlProvider,
    ) !*TabCloseProvider {
        const self = try alloc.create(TabCloseProvider);
        _ = ChromeControlProvider.AddRef(&parent.base);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .fragment = .{ .vtbl = &fragment_vtbl },
            .invoke_iface = .{ .vtbl = &invoke_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .parent = parent,
        };
        return self;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *TabCloseProvider {
        return @fieldParentPtr("base", p);
    }
    fn fromFragment(p: *com.IRawElementProviderFragment) *TabCloseProvider {
        return @fieldParentPtr("fragment", p);
    }
    fn fromInvoke(p: *com.IInvokeProvider) *TabCloseProvider {
        return @fieldParentPtr("invoke_iface", p);
    }

    fn available(self: *const TabCloseProvider) bool {
        return self.parent.closeBounds() != null;
    }

    fn query(self: *TabCloseProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
        } else if (iidEqual(iid, &com.IID_IRawElementProviderFragment)) {
            out.* = @ptrCast(&self.fragment);
        } else if (iidEqual(iid, &com.IID_IInvokeProvider)) {
            out.* = @ptrCast(&self.invoke_iface);
        } else return com.E_NOINTERFACE;
        _ = self.refcount.fetchAdd(1, .monotonic);
        return com.S_OK;
    }
    pub const QueryInterface = Object.Interface("base").QueryInterface;
    const FragmentQueryInterface = Object.Interface("fragment").QueryInterface;
    const InvokeQueryInterface = Object.Interface("invoke_iface").QueryInterface;

    pub const AddRef = Object.Interface("base").AddRef;
    const FragmentAddRef = Object.Interface("fragment").AddRef;
    const InvokeAddRef = Object.Interface("invoke_iface").AddRef;

    fn release(self: *TabCloseProvider) u32 {
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            const parent = self.parent;
            self.alloc.destroy(self);
            _ = ChromeControlProvider.Release(&parent.base);
            return 0;
        }
        return previous - 1;
    }
    pub const Release = Object.Interface("base").Release;
    const FragmentRelease = Object.Interface("fragment").Release;
    const InvokeRelease = Object.Interface("invoke_iface").Release;

    fn get_ProviderOptions(
        p: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider |
            (if (fromBase(p).parent.state.use_com_threading) com.ProviderOptions_UseComThreading else @as(i32, 0));
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
        if (pattern_id != constants.UIA_InvokePatternId) return com.S_OK;
        out.* = @ptrCast(&self.invoke_iface);
        _ = AddRef(&self.base);
        return com.S_OK;
    }

    pub fn GetPropertyValue(
        p: *com.IRawElementProviderSimple,
        property_id: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(p);
        out.* = com.VARIANT.empty();
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        switch (property_id) {
            constants.UIA_ControlTypePropertyId => {
                out.* = com.VARIANT.fromI4(constants.UIA_ButtonControlTypeId);
            },
            constants.UIA_NamePropertyId => {
                var title_buf: [512]u8 = undefined;
                const title = self.parent.state.name(self.parent.state.ctx, self.parent.state.tag, &title_buf);
                var name_buf: [600]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "Close tab: {s}", .{title}) catch "Close tab";
                const bstr = allocBstrFromUtf8(self.alloc, name) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_FrameworkIdPropertyId => return object.frameworkId(out),
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            constants.UIA_IsEnabledPropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_IsKeyboardFocusablePropertyId,
            constants.UIA_HasKeyboardFocusPropertyId,
            => out.* = com.VARIANT.fromBool(false),
            constants.UIA_IsOffscreenPropertyId => {
                out.* = com.VARIANT.fromBool(IsWindowVisible(self.parent.hwnd) == 0);
            },
            else => {},
        }
        return com.S_OK;
    }

    fn get_HostRawElementProvider(
        _: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }

    pub fn Navigate(
        p: *com.IRawElementProviderFragment,
        direction: i32,
        out: *?*com.IRawElementProviderFragment,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (direction == com.NavigateDirection_Parent) {
            out.* = &self.parent.fragment;
            _ = ChromeControlProvider.AddRef(&self.parent.base);
        }
        return com.S_OK; // The close button is the tab's only child.
    }

    pub fn GetRuntimeId(
        p: *com.IRawElementProviderFragment,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return object.runtimeId(&.{ com.UiaAppendRuntimeId, runtime_id_tag, @bitCast(@as(u32, @truncate(self.parent.state.tag))) }, out);
    }

    pub fn GetBoundingRectangle(
        p: *com.IRawElementProviderFragment,
        out: *com.UiaRect,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.parent.closeBounds()) |rect| out.* = rect;
        return com.S_OK;
    }

    fn GetEmbeddedFragmentRoots(
        _: *com.IRawElementProviderFragment,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }

    fn SetFocus(p: *com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        if (!fromFragment(p).available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.E_NOTIMPL;
    }

    fn GetFragmentRoot(
        p: *com.IRawElementProviderFragment,
        out: *?*com.IRawElementProviderFragmentRoot,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = &self.parent.fragment_root;
        _ = ChromeControlProvider.AddRef(&self.parent.base);
        return com.S_OK;
    }

    pub fn Invoke(p: *com.IInvokeProvider) callconv(.winapi) com.HRESULT {
        const self = fromInvoke(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const invoke = self.parent.state.close_invoke orelse return com.UIA_E_INVALIDOPERATION;
        if (!invoke(self.parent.state.ctx, self.parent.state.tag)) return com.UIA_E_INVALIDOPERATION;
        // Raised only once the command is actually on the window's queue,
        // and before returning, which is where UIA expects it.
        events.raiseInvoked(&self.base);
        return com.S_OK;
    }
};

test "PKG71 close child navigation identity bounds names events and detach" {
    const win32 = @import("../win32/sys.zig");
    const hwnd = win32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), 0, 0, 0, 100, 24, null, null, null, null) orelse return error.SkipZigTest;
    defer _ = win32.DestroyWindow(hwnd);
    const Context = struct {
        closable: bool = true,
        calls: usize = 0,
        fn name(_: *anyopaque, _: usize, _: []u8) []const u8 {
            return "inactive shell";
        }
        fn bounds(ctx: *anyopaque, _: usize) ?com.UiaRect {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.closable) return null;
            return .{ .left = 80, .top = 10, .width = 20, .height = 24 };
        }
        fn invoke(ctx: *anyopaque, _: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return true;
        }
    };
    var ctx = Context{};
    const parent = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = &ctx,
        .tag = 42,
        .role = .tab_item,
        .name = Context.name,
        .close_bounds = Context.bounds,
        .close_invoke = Context.invoke,
    });
    defer _ = ChromeControlProvider.Release(&parent.base);
    const events_before = events.testing_structure_changes;
    parent.syncCloseChild();
    parent.syncCloseChild();
    try std.testing.expectEqual(events_before + 1, events.testing_structure_changes);
    var child: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, parent.fragment.vtbl.Navigate(&parent.fragment, com.NavigateDirection_FirstChild, &child));
    try std.testing.expect(child != null);
    defer _ = child.?.vtbl.Release(child.?);
    const close = TabCloseProvider.fromFragment(child.?);
    var hit: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, parent.fragment_root.vtbl.ElementProviderFromPoint(&parent.fragment_root, 90, 20, &hit));
    {
        defer if (hit) |value| {
            _ = value.vtbl.Release(value);
        };
        try std.testing.expect(hit != null and hit != &parent.fragment);
        try std.testing.expect(TabCloseProvider.fromFragment(hit.?).parent == parent);
    }
    try std.testing.expectEqual(com.S_OK, parent.fragment_root.vtbl.ElementProviderFromPoint(&parent.fragment_root, 79, 20, &hit));
    try std.testing.expect(hit == &parent.fragment);
    _ = hit.?.vtbl.Release(hit.?);
    var last: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, parent.fragment.vtbl.Navigate(&parent.fragment, com.NavigateDirection_LastChild, &last));
    defer _ = last.?.vtbl.Release(last.?);
    var id1: ?*com.SAFEARRAY = null;
    var id2: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(com.S_OK, child.?.vtbl.GetRuntimeId(child.?, &id1));
    defer _ = com.SafeArrayDestroy(id1.?);
    try std.testing.expectEqual(com.S_OK, last.?.vtbl.GetRuntimeId(last.?, &id2));
    defer _ = com.SafeArrayDestroy(id2.?);
    for (0..3) |i| {
        var index: i32 = @intCast(i);
        var a: i32 = 0;
        var b: i32 = 0;
        try std.testing.expectEqual(com.S_OK, com.SafeArrayGetElement(id1.?, &index, &a));
        try std.testing.expectEqual(com.S_OK, com.SafeArrayGetElement(id2.?, &index, &b));
        try std.testing.expectEqual(a, b);
    }
    var bounds: com.UiaRect = undefined;
    try std.testing.expectEqual(com.S_OK, child.?.vtbl.get_BoundingRectangle(child.?, &bounds));
    try std.testing.expectEqual(@as(f64, 20), bounds.width);
    var name1 = com.VARIANT.empty();
    var name2 = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, close.base.vtbl.GetPropertyValue(&close.base, constants.UIA_NamePropertyId, &name1));
    defer _ = com.VariantClear(&name1);
    try std.testing.expectEqual(com.S_OK, close.base.vtbl.GetPropertyValue(&close.base, constants.UIA_NamePropertyId, &name2));
    defer _ = com.VariantClear(&name2);
    try std.testing.expect(name1.value.bstr != name2.value.bstr);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Close tab: inactive shell"), std.mem.span(name1.value.bstr.?));
    var link: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, child.?.vtbl.Navigate(child.?, com.NavigateDirection_Parent, &link));
    try std.testing.expect(link == &parent.fragment);
    _ = link.?.vtbl.Release(link.?);
    const invoked_before = events.testing_invocations;
    try std.testing.expectEqual(com.S_OK, close.invoke_iface.vtbl.Invoke(&close.invoke_iface));
    try std.testing.expectEqual(invoked_before + 1, events.testing_invocations);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    ctx.closable = false;
    parent.syncCloseChild();
    try std.testing.expectEqual(com.S_OK, parent.fragment_root.vtbl.ElementProviderFromPoint(&parent.fragment_root, 90, 20, &hit));
    try std.testing.expect(hit == &parent.fragment);
    _ = hit.?.vtbl.Release(hit.?);
    try std.testing.expectEqual(events_before + 2, events.testing_structure_changes);
    try std.testing.expectEqual(com.S_OK, parent.fragment.vtbl.Navigate(&parent.fragment, com.NavigateDirection_FirstChild, &link));
    try std.testing.expect(link == null);
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTAVAILABLE, close.invoke_iface.vtbl.Invoke(&close.invoke_iface));
    ctx.closable = true;
    parent.detach();
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTAVAILABLE, child.?.vtbl.get_BoundingRectangle(child.?, &bounds));
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTAVAILABLE, close.invoke_iface.vtbl.Invoke(&close.invoke_iface));
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
}

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
    const Object = object.ComObject(TerminalProvider, query, release);

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

    pub const QueryInterface = Object.Interface("base").QueryInterface;

    const TextQueryInterface = Object.Interface("text_iface").QueryInterface;

    const Text2QueryInterface = Object.Interface("text2_iface").QueryInterface;

    const ValueQueryInterface = Object.Interface("value_iface").QueryInterface;

    fn query(
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

    pub const AddRef = Object.Interface("base").AddRef;

    const TextAddRef = Object.Interface("text_iface").AddRef;

    const ValueAddRef = Object.Interface("value_iface").AddRef;

    const Text2AddRef = Object.Interface("text2_iface").AddRef;

    pub const Release = Object.Interface("base").Release;

    const TextRelease = Object.Interface("text_iface").Release;

    const ValueRelease = Object.Interface("value_iface").Release;

    const Text2Release = Object.Interface("text2_iface").Release;

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
            constants.UIA_FrameworkIdPropertyId => return object.frameworkId(out),
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
            return com.UIA_E_ELEMENTNOTAVAILABLE;
        }
        return object.hostProvider(self.hwnd, out);
    }

    fn allocCurrentValueBstr(self: *TerminalProvider) com.BSTR {
        const value = self.state.value(self.state.ctx, self.alloc) catch return null;
        defer self.alloc.free(value);
        return allocBstrFromUtf8(self.alloc, value);
    }

    fn SetValue(
        self_value: *com.IValueProvider,
        value_arg: ?[*:0]const u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(self_value);
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.state.role != .edit) return com.UIA_E_INVALIDOPERATION;
        const set_value = self.state.set_value orelse return com.UIA_E_INVALIDOPERATION;
        const value_w = value_arg orelse return com.E_INVALIDARG;
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

        // UIA selection support describes whether a client can mutate the
        // control selection through ITextRangeProvider.Select. Edit controls
        // support one mutable selection; the PTY-owned terminal selection is
        // observable through GetSelection but cannot be changed by UIA.
        out.* = switch (self.state.role) {
            .edit => com.SupportedTextSelection_Single,
            .terminal => com.SupportedTextSelection_None,
        };
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

        const document_offset = self.byteOffsetForScreenPoint(&terminal_snapshot, point);
        return self.createRangeFromSnapshot(
            &terminal_snapshot,
            .{ .start = document_offset, .end = document_offset },
            out,
        );
    }

    fn terminalSnapshot(self: *TerminalProvider) !TerminalSnapshot {
        if (self.detached.load(.acquire)) return error.ElementNotAvailable;
        const raw_snapshot = if (self.state.snapshot) |snapshot_fn| snapshot: {
            break :snapshot try snapshot_fn(self.state.ctx, self.alloc);
        } else snapshot: {
            const document_text = try self.state.value(self.state.ctx, self.alloc);

            break :snapshot TerminalSnapshot{
                .document_text = document_text,
                .visible_range = .{ .start = 0, .end = document_text.len },
                .caret_offset = document_text.len,
            };
        };

        const raw_start = @min(raw_snapshot.visible_range.start, raw_snapshot.document_text.len);
        const raw_end = @min(@max(raw_start, raw_snapshot.visible_range.end), raw_snapshot.document_text.len);
        const visible_start = utf8BoundaryAtOrBefore(raw_snapshot.document_text, raw_start);
        const visible_end = utf8BoundaryAtOrBefore(raw_snapshot.document_text, raw_end);
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

        const visible_offset = byteOffsetForClientPoint(snapshot.visibleText(), client_rect, client_point);
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
    const Object = object.ComObject(TerminalTextRangeProvider, query, release);

    fn query(self: *TerminalTextRangeProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
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

    fn release(self: *TerminalTextRangeProvider) u32 {
        const prev = self.refcount.fetchSub(1, .acq_rel);
        if (prev == 1) {
            self.snapshot.release();
            _ = TerminalProvider.Release(&self.parent.base);
            self.alloc.destroy(self);
            return 0;
        }
        return prev - 1;
    }

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

    const QueryInterface = Object.Interface("base").QueryInterface;

    const AddRef = Object.Interface("base").AddRef;

    const Release = Object.Interface("base").Release;

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

    /// Report no rectangles, as an empty array rather than a null one.
    fn noRectangles(out: *?*com.SAFEARRAY) com.HRESULT {
        out.* = com.SafeArrayCreateVector(com.VT_R8, 0, 0);
        return if (out.* == null) com.E_OUTOFMEMORY else com.S_OK;
    }

    fn GetBoundingRectangles(
        self_base: *com.ITextRangeProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        var geometry = self.geometry orelse return noRectangles(out);
        var row_shift: i64 = 0;
        if (self.parent.state.current_viewport) |current_viewport| {
            const current = current_viewport(self.parent.state.ctx) catch |err| {
                if (err == error.ElementNotAvailable) return com.UIA_E_ELEMENTNOTAVAILABLE;
                return noRectangles(out);
            };
            if (current == null or geometry.row_numbering == null or
                !std.meta.eql(geometry.row_numbering.?, current.?.row_numbering))
            {
                return noRectangles(out);
            }
            const live = current.?;
            row_shift = @as(i64, @intCast(geometry.viewport_y)) - @as(i64, @intCast(live.viewport_y));
            geometry.viewport_rows = live.row_numbering.rows;
            geometry.viewport_columns = live.row_numbering.columns;
            geometry.cell_width = live.cell_width;
            geometry.cell_height = live.cell_height;
            geometry.origin_x = live.origin_x;
            geometry.origin_y = live.origin_y;
        }
        var screen_origin: POINT = .{ .x = 0, .y = 0 };
        if (ClientToScreen(self.parent.hwnd, &screen_origin) == 0) return noRectangles(out);

        const capacity = @as(usize, geometry.viewport_rows) * 4;
        const values = self.alloc.alloc(f64, capacity) catch return com.E_OUTOFMEMORY;
        defer self.alloc.free(values);
        const value_count = terminalGridRectangleValues(
            self.text,
            self.range,
            geometry,
            row_shift,
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
        align_to_top: com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        if (self.parent.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const scroll = self.parent.state.scroll_range orelse return com.E_NOTIMPL;
        const geometry = self.geometry orelse return com.UIA_E_INVALIDOPERATION;
        const token = geometry.scroll_token orelse return com.UIA_E_INVALIDOPERATION;
        if (geometry.cell_for_byte.len != self.text.len or self.text.len == 0) return com.UIA_E_INVALIDOPERATION;
        // End is exclusive. A degenerate range uses the insertion cell (or
        // the last cell at document end), never the next line of a range.
        const offset = if (align_to_top != 0 or self.range.start == self.range.end)
            @min(self.range.start, self.text.len - 1)
        else
            @min(self.range.end -| 1, self.text.len - 1);
        const absolute_row = @as(i64, @intCast(geometry.viewport_y)) + geometry.cell_for_byte[offset].row;
        if (absolute_row < 0) return com.UIA_E_INVALIDOPERATION;
        scroll(self.parent.state.ctx, .{
            .token = token,
            .document_window = geometry.document_window,
            .absolute_row = @intCast(absolute_row),
            .align_to_top = align_to_top != 0,
        }) catch |err| return if (err == error.ElementNotAvailable) com.UIA_E_ELEMENTNOTAVAILABLE else com.UIA_E_INVALIDOPERATION;
        return com.S_OK;
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
    row_shift: i64,
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
        const shifted_row = @as(i64, cell.row) + row_shift;
        if (cell.width == 0 or shifted_row < 0 or shifted_row >= geometry.viewport_rows) continue;
        const cell_row: i32 = @intCast(shifted_row);
        if (active_row == null or active_row.? != cell_row) {
            if (active_row) |row| {
                if (written + 4 > values.len) break;
                writeGridRectangle(values[written..][0..4], screen_origin, geometry, row, min_column, max_column);
                written += 4;
            }
            active_row = cell_row;
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

    var focus_fragment: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(
        com.S_OK,
        PaletteListProvider.FragmentRootGetFocus(&provider.fragment_root, &focus_fragment),
    );
    try std.testing.expect(focus_fragment == &provider.fragment);
    _ = PaletteListProvider.FragmentRelease(focus_fragment.?);
}

test "PaletteListProvider with the focus on its rows gives it to the selected one, and reads their help text" {
    const callbacks = struct {
        var focused_now = true;
        fn focused(_: *anyopaque) bool {
            return focused_now;
        }
        fn rowHelp(_: *anyopaque, index: usize, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "help for row {d}", .{index}) catch "";
        }
    };
    callbacks.focused_now = true;
    var state_data = TestPaletteState{ .count = 3, .selected = 1 };
    var state = state_data.state();
    state.keyboard_focusable = true;
    state.focused = callbacks.focused;
    state.help_text = "Up and Down move";
    state.row_help = callbacks.rowHelp;
    state.focus_selected_row = true;
    const list = try settings_provider_windows.create("STATIC");
    var list_alive = true;
    defer if (list_alive) {
        _ = settings_provider_windows.DestroyWindow(list);
    };
    const provider = try PaletteListProvider.create(std.testing.allocator, list, state);
    defer _ = PaletteListProvider.Release(&provider.base);

    // The list says how to use it, and leaves the focus to its selected row.
    try expectBstrProperty(&provider.base, constants.UIA_HelpTextPropertyId, "Up and Down move");
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.GetPropertyValue(&provider.base, constants.UIA_HasKeyboardFocusPropertyId, &value));
    try std.testing.expectEqual(com.VARIANT_FALSE, value.value.bool_val);
    var focus: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.FragmentRootGetFocus(&provider.fragment_root, &focus));
    try std.testing.expectEqual(@as(usize, 1), PaletteRowProvider.fromFragment(focus.?).index);
    _ = PaletteRowProvider.FragmentRelease(focus.?);

    // Each row reads its own help text; the selected one has the focus.
    for (0..3) |index| {
        const row = provider.createRow(index).?;
        defer _ = PaletteRowProvider.Release(&row.base);
        var help: [32]u8 = undefined;
        try expectBstrProperty(&row.base, constants.UIA_HelpTextPropertyId, try std.fmt.bufPrint(&help, "help for row {d}", .{index}));
        for ([_]i32{ constants.UIA_HasKeyboardFocusPropertyId, constants.UIA_IsKeyboardFocusablePropertyId }, [_]bool{ index == 1, true }) |property, expected| {
            value = com.VARIANT.empty();
            try std.testing.expectEqual(com.S_OK, PaletteRowProvider.GetPropertyValue(&row.base, property, &value));
            try std.testing.expectEqual(if (expected) com.VARIANT_TRUE else com.VARIANT_FALSE, value.value.bool_val);
        }
    }

    // SetFocus on a row selects it and focuses the list.
    const first = provider.createRow(0).?;
    defer _ = PaletteRowProvider.Release(&first.base);
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.SetFocus(&first.fragment));
    try std.testing.expectEqual(@as(?usize, 0), state_data.selected_by_provider);
    try std.testing.expect(hwndHasKeyboardFocus(list));
    // A list window already gone (torn down while a client still holds the
    // row) takes no focus, and the row says so rather than reporting success.
    _ = settings_provider_windows.DestroyWindow(list);
    list_alive = false;
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTAVAILABLE, PaletteRowProvider.SetFocus(&first.fragment));

    // A list without the focus has none to give.
    callbacks.focused_now = false;
    focus = null;
    try std.testing.expectEqual(com.S_OK, PaletteListProvider.FragmentRootGetFocus(&provider.fragment_root, &focus));
    try std.testing.expect(focus == null);
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
    invoked_by_provider: ?usize = null,
    reentrant_provider: ?*PaletteListProvider = null,
    reentrant_queries: u32 = 0,
    list_geometry: ?PaletteListGeometry = null,
    row_bounds: ?[]const PaletteListRowBounds = null,
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

    fn invokeRow(ctx: *anyopaque, index: usize) void {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        self.invoked_by_provider = index;
    }

    fn geometry(ctx: *anyopaque) ?PaletteListGeometry {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        return self.list_geometry;
    }

    fn rowBounds(ctx: *anyopaque, index: usize) ?PaletteListRowBounds {
        const self: *TestPaletteState = @ptrCast(@alignCast(ctx));
        const bounds = self.row_bounds orelse return null;
        return if (index < bounds.len) bounds[index] else null;
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
            .invoke_row = invokeRow,
            .geometry = geometry,
            .row_bounds = if (self.row_bounds != null) rowBounds else null,
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

test "Palette sparse row bounds support geometry and hit testing" {
    const rows = [_]PaletteListRowBounds{
        .{ .left = 100, .top = 200, .width = 30, .height = 20 },
        .{ .left = 300, .top = 400, .width = 40, .height = 25 },
    };
    var state_data = TestPaletteState{
        .count = rows.len,
        .selected = 0,
        .row_bounds = &rows,
    };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);

    try std.testing.expectEqual(rows[1], provider.rowBounds(1).?);

    var root_bounds: com.UiaRect = undefined;
    try std.testing.expectEqual(
        com.S_OK,
        PaletteListProvider.FragmentGetBoundingRectangle(&provider.fragment, &root_bounds),
    );
    try std.testing.expectEqual(@as(f64, 100), root_bounds.left);
    try std.testing.expectEqual(@as(f64, 200), root_bounds.top);
    try std.testing.expectEqual(@as(f64, 240), root_bounds.width);
    try std.testing.expectEqual(@as(f64, 225), root_bounds.height);

    var hit: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(
        com.S_OK,
        PaletteListProvider.FragmentRootElementProviderFromPoint(
            &provider.fragment_root,
            310,
            410,
            &hit,
        ),
    );
    try std.testing.expect(hit != null);
    if (hit) |fragment| {
        const row = PaletteRowProvider.fromFragment(fragment);
        try std.testing.expectEqual(@as(usize, 1), row.index);
        _ = PaletteRowProvider.Release(&row.base);
    }
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
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTENABLED, PaletteRowProvider.Invoke(&row.invoke_item));
    try std.testing.expectEqual(@as(?usize, null), state_data.selected_by_provider);
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTENABLED, PaletteRowProvider.SetFocus(&row.fragment));
}

test "Palette row exposes InvokePattern and invokes its callback" {
    var state_data = TestPaletteState{ .count = 2 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);
    const row = provider.createRow(1).?;
    defer _ = PaletteRowProvider.Release(&row.base);

    var pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        PaletteRowProvider.GetPatternProvider(&row.base, constants.UIA_InvokePatternId, &pattern),
    );
    try std.testing.expect(pattern != null);
    _ = PaletteRowProvider.InvokeRelease(@ptrCast(@alignCast(pattern.?)));
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.Invoke(&row.invoke_item));
    try std.testing.expectEqual(@as(?usize, 1), state_data.invoked_by_provider);
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

test "Palette row a client holds follows its item when the list reorders" {
    var state_data = TestPaletteState{ .count = 3, .id_base = 100 };
    var provider = try PaletteListProvider.create(std.testing.allocator, @ptrFromInt(0x1), state_data.state());
    defer _ = PaletteListProvider.Release(&provider.base);
    // The item of id 102, third.
    const row = provider.createRow(2).?;
    defer _ = PaletteRowProvider.Release(&row.base);

    // An item sorted in before it: id 102 is fourth now, and the held row is
    // that item there, named and selected as it.
    state_data.count = 4;
    state_data.id_base = 99;
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.GetPropertyValue(&row.base, constants.UIA_NamePropertyId, &value));
    defer _ = com.VariantClear(&value);
    const bstr = value.value.bstr.?;
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("row 3", buf[0..try std.unicode.utf16LeToUtf8(&buf, bstr[0..com.SysStringLen(bstr)])]);
    try std.testing.expectEqual(com.S_OK, PaletteRowProvider.Select(&row.selection_item));
    try std.testing.expectEqual(@as(?usize, 3), state_data.selected_by_provider);

    // Gone from the list: not available, at any index.
    state_data.id_base = 200;
    var gone = com.VARIANT.empty();
    try std.testing.expectEqual(com.UIA_E_ELEMENTNOTAVAILABLE, PaletteRowProvider.GetPropertyValue(&row.base, constants.UIA_NamePropertyId, &gone));
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
    const Case = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var state_data = TestTerminalStateData{ .caret_offset = 6 };
            var provider = try TerminalProvider.create(alloc, @ptrFromInt(0x1), testTerminalState(&state_data));
            defer _ = TerminalProvider.Release(&provider.base);
            var active: com.BOOL = 1;
            var caret: ?*com.ITextRangeProvider = @ptrFromInt(0x10);
            const result = TerminalProvider.GetCaretRange(&provider.text2_iface, &active, &caret);
            if (result == com.E_OUTOFMEMORY) {
                try std.testing.expectEqual(@as(com.BOOL, 0), active);
                try std.testing.expect(caret == null);
                return error.OutOfMemory;
            }
            try std.testing.expectEqual(com.S_OK, result);
            defer _ = TerminalTextRangeProvider.Release(caret.?);
            try std.testing.expectEqual(@as(com.BOOL, 1), active);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
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

    // The terminal selection is PTY-owned and observable but not mutable by
    // UIA clients.
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
        0,
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
        terminalGridRectangleValues(text, .{ .start = 6, .end = 6 }, geometry, 0, .{ .x = 10, .y = 20 }, &values),
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
        .visible_range = .{ .start = 2, .end = 8 },
    };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    const snapshot = try provider.terminalSnapshot();
    defer std.testing.allocator.free(snapshot.document_text);
    defer if (snapshot.geometry) |geometry| std.testing.allocator.free(geometry.cell_for_byte);
    try std.testing.expectEqualStrings("🔥B", snapshot.visibleText());

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
        .visible_range = .{ .start = 0, .end = 11 },
        .caret_offset = 11,
        .terminal_selection_range = .{ .start = 0, .end = 5 },
        .terminal_selection_active_offset = 5,
    };
    var provider = try TerminalProvider.create(
        std.testing.allocator,
        @ptrFromInt(0x1),
        testTerminalState(&data),
    );
    defer _ = TerminalProvider.Release(&provider.base);

    // The active terminal selection remains observable through GetSelection,
    // but UIA cannot mutate it through Select.
    var supported: i32 = com.SupportedTextSelection_None;
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
    try std.testing.expectEqual(@as(com.HRESULT, com.UIA_E_ELEMENTNOTAVAILABLE), hr);
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

test "PKG71 held range rectangles follow scrolling wheel motion and current metrics" {
    const win32 = @import("../win32/sys.zig");
    const hwnd = win32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), 0, 0, 0, 100, 100, null, null, null, null) orelse return error.SkipZigTest;
    defer _ = win32.DestroyWindow(hwnd);
    const Hook = struct {
        viewport_y: usize = 100,
        cell_width: f64 = 8,
        cell_height: f64 = 16,
        origin_x: f64 = 4,
        origin_y: f64 = 6,
        numbering: terminal_text.RowNumbering = .{ .active_key = 0, .page_serial_min = 1, .first_page_serial = 1, .rows = 3, .columns = 10 },
        available: bool = true,
        snapshot_calls: usize = 0,
        fn name(_: *anyopaque, _: []u8) []const u8 {
            return "terminal";
        }
        fn value(_: *anyopaque, alloc: std.mem.Allocator) ![]u8 {
            return alloc.dupe(u8, "a");
        }
        fn focused(_: *anyopaque) bool {
            return true;
        }
        fn scroll(ctx: *anyopaque, request: ScrollRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.viewport_y = request.absolute_row - if (request.align_to_top) @as(usize, 0) else 2;
        }
        fn snapshot(ctx: *anyopaque, _: std.mem.Allocator) !TerminalSnapshot {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.snapshot_calls += 1;
            return error.UnexpectedSnapshotCopy;
        }
        fn viewport(ctx: *anyopaque) !?TerminalViewportGeometry {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.available) return null;
            return .{
                .row_numbering = self.numbering,
                .viewport_y = self.viewport_y,
                .cell_width = self.cell_width,
                .cell_height = self.cell_height,
                .origin_x = self.origin_x,
                .origin_y = self.origin_y,
            };
        }
        fn expectBounds(range: *com.ITextRangeProvider, expected_y: f64, expected_width: f64, expected_height: f64) !void {
            var rects: ?*com.SAFEARRAY = null;
            try std.testing.expectEqual(com.S_OK, range.vtbl.GetBoundingRectangles(range, &rects));
            defer if (rects) |array| {
                _ = com.SafeArrayDestroy(array);
            };
            var upper: i32 = -1;
            try std.testing.expectEqual(com.S_OK, com.SafeArrayGetUBound(rects.?, 1, &upper));
            try std.testing.expectEqual(@as(i32, 3), upper);
            var y_index: i32 = 1;
            var actual: f64 = 0;
            try std.testing.expectEqual(com.S_OK, com.SafeArrayGetElement(rects.?, &y_index, &actual));
            try std.testing.expectEqual(expected_y, actual);
            var width_index: i32 = 2;
            try std.testing.expectEqual(com.S_OK, com.SafeArrayGetElement(rects.?, &width_index, &actual));
            try std.testing.expectEqual(expected_width, actual);
            var height_index: i32 = 3;
            try std.testing.expectEqual(com.S_OK, com.SafeArrayGetElement(rects.?, &height_index, &actual));
            try std.testing.expectEqual(expected_height, actual);
        }
    };
    var ctx = Hook{};
    const provider = try TerminalProvider.create(std.testing.allocator, hwnd, .{ .ctx = &ctx, .name = Hook.name, .value = Hook.value, .focused = Hook.focused, .snapshot = Hook.snapshot, .scroll_range = Hook.scroll, .current_viewport = Hook.viewport });
    defer _ = TerminalProvider.Release(&provider.base);
    const cells = try std.testing.allocator.alloc(terminal_text.TerminalCellPosition, 1);
    cells[0] = .{ .row = -2, .column = 0, .width = 1 };
    const range = try TerminalTextRangeProvider.createOwnedWithGeometry(std.testing.allocator, provider, try std.testing.allocator.dupe(u8, "a"), .{ .start = 0, .end = 1 }, .{
        .cell_for_byte = cells,
        .scroll_token = 7,
        .viewport_y = 100,
        .document_window = .{ .top = 98, .bottom = 102 },
        .row_numbering = ctx.numbering,
        .viewport_rows = 3,
        .viewport_columns = 10,
        .cell_width = 8,
        .cell_height = 16,
        .origin_x = 4,
        .origin_y = 6,
    });
    defer _ = TerminalTextRangeProvider.Release(&range.base);
    var origin: POINT = .{ .x = 0, .y = 0 };
    try std.testing.expect(ClientToScreen(hwnd, &origin) != 0);
    const screen_y: f64 = @floatFromInt(origin.y);
    try std.testing.expectEqual(com.S_OK, range.base.vtbl.ScrollIntoView(&range.base, 1));
    try Hook.expectBounds(&range.base, screen_y + 6, 8, 16);
    try std.testing.expectEqual(com.S_OK, range.base.vtbl.ScrollIntoView(&range.base, 0));
    try Hook.expectBounds(&range.base, screen_y + 38, 8, 16);
    ctx.viewport_y = 97;
    ctx.cell_width = 10;
    ctx.cell_height = 20;
    ctx.origin_y = 9;
    try Hook.expectBounds(&range.base, screen_y + 29, 10, 20);
    try std.testing.expectEqual(@as(usize, 0), ctx.snapshot_calls);
    // Contention/unavailable geometry and every renumbering cause refuse old
    // rectangles rather than returning coordinates from another document.
    const numbering = ctx.numbering;
    for (0..8) |cause| {
        ctx.numbering = numbering;
        ctx.available = true;
        switch (cause) {
            0 => ctx.available = false,
            1 => ctx.numbering.active_key += 1,
            2 => ctx.numbering.page_serial_min += 1,
            3 => ctx.numbering.first_page_serial += 1,
            4 => ctx.numbering.rows += 1,
            5 => ctx.numbering.columns += 1,
            6 => ctx.numbering.row_generation += 1,
            7 => ctx.numbering.screen_generation += 1,
            else => unreachable,
        }
        var rects: ?*com.SAFEARRAY = null;
        try std.testing.expectEqual(com.S_OK, range.base.vtbl.GetBoundingRectangles(&range.base, &rects));
        defer _ = com.SafeArrayDestroy(rects.?);
        var upper: i32 = 0;
        try std.testing.expectEqual(com.S_OK, com.SafeArrayGetUBound(rects.?, 1, &upper));
        try std.testing.expectEqual(@as(i32, -1), upper);
    }
    // A captured visible row must also move away from its old on-screen y.
    ctx = Hook{};
    const visible_cells = try std.testing.allocator.alloc(terminal_text.TerminalCellPosition, 1);
    visible_cells[0] = .{ .row = 1, .column = 0, .width = 1 };
    var visible_geometry = range.geometry.?;
    visible_geometry.cell_for_byte = visible_cells;
    const visible = try TerminalTextRangeProvider.createOwnedWithGeometry(std.testing.allocator, provider, try std.testing.allocator.dupe(u8, "a"), .{ .start = 0, .end = 1 }, visible_geometry);
    defer _ = TerminalTextRangeProvider.Release(&visible.base);
    try Hook.expectBounds(&visible.base, screen_y + 22, 8, 16);
    try std.testing.expectEqual(com.S_OK, visible.base.vtbl.ScrollIntoView(&visible.base, 1));
    try Hook.expectBounds(&visible.base, screen_y + 6, 8, 16);
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, range.base.vtbl.Select(&range.base));

    // Exercise the real no-scrollback erasure path with a held COM range,
    // rather than only synthesizing a changed provenance field above.
    const terminal = @import("../../terminal/main.zig");
    for (0..5) |path| {
        var t = try terminal.Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
        defer t.deinit(std.testing.allocator);
        if (path < 3) _ = try t.switchScreen(.alternate);
        try t.printString("a\r\nb\r\nc");
        ctx = Hook{ .viewport_y = 0, .numbering = terminal_text.rowNumbering(&t) };
        var held_geometry = visible_geometry;
        held_geometry.cell_for_byte = try std.testing.allocator.dupe(terminal_text.TerminalCellPosition, &.{.{ .row = 1, .column = 0, .width = 1 }});
        held_geometry.viewport_y = 0;
        held_geometry.row_numbering = ctx.numbering;
        const held = try TerminalTextRangeProvider.createOwnedWithGeometry(std.testing.allocator, provider, try std.testing.allocator.dupe(u8, "b"), .{ .start = 0, .end = 1 }, held_geometry);
        defer _ = TerminalTextRangeProvider.Release(&held.base);
        try Hook.expectBounds(&held.base, screen_y + 22, 8, 16);
        switch (path) {
            0 => try t.screens.active.cursorDownScroll(),
            1 => try t.screens.active.pages.eraseRowBounded(.{ .active = .{} }, 1),
            2 => {
                t.setCursorPos(1, 1);
                t.reverseIndex();
            },
            3 => {
                t.scrolling_region.top = 1;
                t.setCursorPos(2, 1);
                t.deleteLines(1);
            },
            4 => {
                t.scrolling_region.bottom = 1;
                t.setCursorPos(2, 1);
                try t.index();
            },
            else => unreachable,
        }
        ctx.numbering = terminal_text.rowNumbering(&t);
        var rects: ?*com.SAFEARRAY = null;
        try std.testing.expectEqual(com.S_OK, held.base.vtbl.GetBoundingRectangles(&held.base, &rects));
        defer _ = com.SafeArrayDestroy(rects.?);
        var upper: i32 = 0;
        try std.testing.expectEqual(com.S_OK, com.SafeArrayGetUBound(rects.?, 1, &upper));
        try std.testing.expectEqual(@as(i32, -1), upper);
    }
}

test "PKG71 ScrollIntoView dispatches frozen endpoint and alignment without selecting" {
    const Hook = struct {
        var request: ?ScrollRequest = null;
        fn scroll(_: *anyopaque, value: ScrollRequest) !void {
            request = value;
        }
    };
    Hook.request = null;
    var data = TestTerminalStateData{};
    var state = testTerminalState(&data);
    state.scroll_range = Hook.scroll;
    const provider = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(1), state);
    defer _ = TerminalProvider.Release(&provider.base);
    const cells = [_]terminal_text.TerminalCellPosition{
        .{ .row = -2, .column = 0, .width = 1 },
        .{ .row = -1, .column = 0, .width = 1 },
    };
    const range = try TerminalTextRangeProvider.createOwnedWithGeometry(std.testing.allocator, provider, try std.testing.allocator.dupe(u8, "ab"), .{ .start = 0, .end = 2 }, .{
        .cell_for_byte = try std.testing.allocator.dupe(terminal_text.TerminalCellPosition, &cells),
        .scroll_token = 7,
        .viewport_y = 100,
        .document_window = .{ .top = 98, .bottom = 102 },
        .viewport_rows = 3,
        .viewport_columns = 5,
        .cell_width = 1,
        .cell_height = 1,
        .origin_x = 0,
        .origin_y = 0,
    });
    defer _ = TerminalTextRangeProvider.Release(&range.base);
    try std.testing.expectEqual(com.S_OK, range.base.vtbl.ScrollIntoView(&range.base, 1));
    try std.testing.expect(Hook.request != null);
    try std.testing.expectEqual(@as(usize, 98), Hook.request.?.absolute_row);
    try std.testing.expectEqual(@as(u32, 98), Hook.request.?.document_window.top);
    try std.testing.expect(Hook.request.?.align_to_top);
    try std.testing.expectEqual(com.S_OK, range.base.vtbl.ScrollIntoView(&range.base, 0));
    try std.testing.expectEqual(@as(usize, 99), Hook.request.?.absolute_row);
    try std.testing.expect(!Hook.request.?.align_to_top);
    try std.testing.expectEqual(com.UIA_E_INVALIDOPERATION, range.base.vtbl.Select(&range.base));
}

test "PKG71 tab item exposes a fragment root for its close child" {
    var context: u8 = 0;
    const Name = struct {
        fn name(_: *anyopaque, _: usize, _: []u8) []const u8 {
            return "Tab";
        }
    };
    const provider = try ChromeControlProvider.create(std.testing.allocator, @ptrFromInt(1), .{
        .ctx = &context,
        .role = .tab_item,
        .tag = 42,
        .name = Name.name,
    });
    defer _ = ChromeControlProvider.Release(&provider.base);
    var out: ?*anyopaque = null;
    const hr = provider.base.vtbl.QueryInterface(&provider.base, &com.IID_IRawElementProviderFragmentRoot, &out);
    defer if (hr == com.S_OK) {
        _ = ChromeControlProvider.Release(&provider.base);
    };
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
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

test "ChromeControlProvider keyboard focusability follows the role unless overridden" {
    const Context = struct {
        fn name(_: *anyopaque, tag: usize, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "chrome {d}", .{tag}) catch "";
        }
    };

    const GetDesktopWindow = struct {
        extern "user32" fn GetDesktopWindow() callconv(.winapi) com.HWND;
    }.GetDesktopWindow;
    const hwnd = GetDesktopWindow();
    var context: u8 = 0;
    const context_ptr: *anyopaque = @ptrCast(&context);

    // A live-region text element is not focusable by role.
    const notice = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .live_text,
        .name = Context.name,
    });
    defer _ = ChromeControlProvider.Release(&notice.base);
    defer notice.detach();

    // The same role on a focus-region landing site must not claim to be
    // unfocusable while the cycle parks real keyboard focus on it.
    const banner = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .live_text,
        .name = Context.name,
        .keyboard_focusable = true,
    });
    defer _ = ChromeControlProvider.Release(&banner.base);
    defer banner.detach();

    // An override can also take focusability away from an interactive role.
    const inert_button = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = context_ptr,
        .role = .button,
        .name = Context.name,
        .keyboard_focusable = false,
    });
    defer _ = ChromeControlProvider.Release(&inert_button.base);
    defer inert_button.detach();

    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetPropertyValue(
        &notice.base,
        constants.UIA_IsKeyboardFocusablePropertyId,
        &value,
    ));
    try std.testing.expectEqual(com.VARIANT_FALSE, value.value.bool_val);

    value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetPropertyValue(
        &banner.base,
        constants.UIA_IsKeyboardFocusablePropertyId,
        &value,
    ));
    try std.testing.expectEqual(com.VARIANT_TRUE, value.value.bool_val);

    value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetPropertyValue(
        &inert_button.base,
        constants.UIA_IsKeyboardFocusablePropertyId,
        &value,
    ));
    try std.testing.expectEqual(com.VARIANT_FALSE, value.value.bool_val);
}

test "ChromeControlProvider reports the tooltip role as the SDK's ToolTip control type" {
    const Context = struct {
        fn name(_: *anyopaque, _: usize, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "full tab title", .{}) catch "";
        }
    };

    const GetDesktopWindow = struct {
        extern "user32" fn GetDesktopWindow() callconv(.winapi) com.HWND;
    }.GetDesktopWindow;
    var context: u8 = 0;
    const tooltip = try ChromeControlProvider.create(std.testing.allocator, GetDesktopWindow(), .{
        .ctx = @ptrCast(&context),
        .role = .tooltip,
        .name = Context.name,
    });
    defer _ = ChromeControlProvider.Release(&tooltip.base);
    defer tooltip.detach();

    // UIA_ToolTipControlTypeId in UIAutomationClient.h. The literal is the
    // point: asking the constant would agree with a wrong constant.
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetPropertyValue(
        &tooltip.base,
        constants.UIA_ControlTypePropertyId,
        &value,
    ));
    try std.testing.expectEqual(@as(i32, 50022), value.value.i4);
}

test "ChromeControlProvider hidden chrome is not keyboard focusable" {
    const Context = struct {
        fn name(_: *anyopaque, tag: usize, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "tab {d}", .{tag}) catch "";
        }
    };

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
        extern "user32" fn ShowWindow(hWnd: com.HWND, nCmdShow: i32) callconv(.winapi) com.BOOL;
    };

    // `window-show-tab-bar = never` hides the tab buttons and the [+] / [▾]
    // cluster but keeps the HWNDs (and their providers) alive. The host's
    // focus-region cycle filters candidates through `IsWindowVisible`, so a
    // hidden control must not advertise itself as a focus target.
    const hwnd = win32.CreateWindowExW(
        0x0000_0080, // WS_EX_TOOLWINDOW
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        0x8000_0000, // WS_POPUP
        -32_000,
        -32_000,
        100,
        24,
        null,
        null,
        null,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = win32.DestroyWindow(hwnd);

    var context: u8 = 0;
    const item = try ChromeControlProvider.create(std.testing.allocator, hwnd, .{
        .ctx = @ptrCast(&context),
        .role = .tab_item,
        .tag = 1,
        .name = Context.name,
    });
    defer _ = ChromeControlProvider.Release(&item.base);
    defer item.detach();

    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetPropertyValue(
        &item.base,
        constants.UIA_IsKeyboardFocusablePropertyId,
        &value,
    ));
    try std.testing.expectEqual(com.VARIANT_FALSE, value.value.bool_val);

    _ = win32.ShowWindow(hwnd, 4); // SW_SHOWNOACTIVATE
    value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, ChromeControlProvider.GetPropertyValue(
        &item.base,
        constants.UIA_IsKeyboardFocusablePropertyId,
        &value,
    ));
    try std.testing.expectEqual(com.VARIANT_TRUE, value.value.bool_val);
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

test "SettingsControlProvider exposes ValueProvider for edits and combos" {
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

test "SettingsControlProvider layout pane stays out of the control and content views" {
    const win32 = @import("../win32/sys.zig");
    const empty_title = std.unicode.utf8ToUtf16LeStringLiteral("");
    const hwnd = win32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
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
    defer _ = win32.DestroyWindow(hwnd);
    // A field inside the pane has the focus; the pane must not claim it.
    const child = win32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        empty_title,
        0x40000000,
        0,
        0,
        80,
        24,
        hwnd,
        @ptrFromInt(44),
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(child);
    _ = win32.SetFocus(child);
    try std.testing.expect(hwndHasKeyboardFocus(hwnd));

    const pane = try SettingsControlProvider.create(std.testing.allocator, hwnd, .layout_pane, null);
    defer _ = SettingsControlProvider.Release(&pane.base);
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&pane.base, constants.UIA_ControlTypePropertyId, &value));
    try std.testing.expectEqual(constants.UIA_PaneControlTypeId, value.value.i4);
    for ([_]i32{
        constants.UIA_IsControlElementPropertyId,
        constants.UIA_IsContentElementPropertyId,
        constants.UIA_IsKeyboardFocusablePropertyId,
        constants.UIA_HasKeyboardFocusPropertyId,
    }) |property| {
        try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&pane.base, property, &value));
        try std.testing.expectEqual(com.VT_BOOL, value.vt);
        try std.testing.expectEqual(@as(i16, 0), value.value.bool_val);
    }
    // A field keeps reading as a control.
    const field = try SettingsControlProvider.create(std.testing.allocator, hwnd, .edit, "Font size");
    defer _ = SettingsControlProvider.Release(&field.base);
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&field.base, constants.UIA_IsControlElementPropertyId, &value));
    try std.testing.expect(value.value.bool_val != 0);
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

const settings_provider_windows = struct {
    const sys = @import("../win32/sys.zig");
    const DestroyWindow = sys.DestroyWindow;

    fn create(comptime class: []const u8) !com.HWND {
        return sys.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral(class),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            0,
            0,
            0,
            100,
            100,
            null,
            null,
            null,
            null,
        ) orelse error.TestUnexpectedResult;
    }
};

fn expectBstrProperty(p: *com.IRawElementProviderSimple, property: i32, expected: []const u8) !void {
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, p.vtbl.GetPropertyValue(p, property, &value));
    defer _ = com.VariantClear(&value);
    try std.testing.expectEqual(@as(u16, com.VT_BSTR), value.vt);
    var expected_w: [64]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&expected_w, expected);
    const bstr = value.value.bstr.?;
    try std.testing.expectEqualSlices(u16, expected_w[0..length], bstr[0..com.SysStringLen(bstr)]);
}

test "SettingsControlProvider live text is a Text element a reader speaks when it changes" {
    const hwnd = try settings_provider_windows.create("STATIC");
    defer _ = settings_provider_windows.DestroyWindow(hwnd);
    const live = try SettingsControlProvider.create(std.testing.allocator, hwnd, .live_text, null);
    defer _ = SettingsControlProvider.Release(&live.base);
    const plain = try SettingsControlProvider.create(std.testing.allocator, hwnd, .text, null);
    defer _ = SettingsControlProvider.Release(&plain.base);

    for ([_]*SettingsControlProvider{ live, plain }) |provider| {
        var value = com.VARIANT.empty();
        try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&provider.base, constants.UIA_ControlTypePropertyId, &value));
        try std.testing.expectEqual(constants.UIA_TextControlTypeId, value.value.i4);
        // Neither takes keyboard focus nor offers a pattern.
        try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&provider.base, constants.UIA_IsKeyboardFocusablePropertyId, &value));
        try std.testing.expectEqual(@as(i16, com.VARIANT_FALSE), value.value.bool_val);
        var pattern: ?*com.IUnknown = null;
        try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPatternProvider(&provider.base, constants.UIA_ValuePatternId, &pattern));
        try std.testing.expect(pattern == null);
    }

    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&live.base, constants.UIA_LiveSettingPropertyId, &value));
    try std.testing.expectEqual(@as(u16, com.VT_I4), value.vt);
    try std.testing.expectEqual(constants.LiveSetting_Polite, value.value.i4);
    // Ordinary text is not a live region.
    value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&plain.base, constants.UIA_LiveSettingPropertyId, &value));
    try std.testing.expectEqual(@as(u16, com.VT_EMPTY), value.vt);
}

test "SettingsControlProvider reports a field whose value Settings will not accept" {
    const hwnd = try settings_provider_windows.create("EDIT");
    defer _ = settings_provider_windows.DestroyWindow(hwnd);
    const edit = try SettingsControlProvider.create(std.testing.allocator, hwnd, .edit, "Font size");
    defer _ = SettingsControlProvider.Release(&edit.base);

    var value = com.VARIANT.empty();
    // A field nothing is wrong with says so: left out, the property reads as
    // FALSE (measured through UIA on a running window).
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&edit.base, constants.UIA_IsDataValidForFormPropertyId, &value));
    try std.testing.expectEqual(@as(u16, com.VT_BOOL), value.vt);
    try std.testing.expectEqual(@as(i16, com.VARIANT_TRUE), value.value.bool_val);

    events.testing_property_changes = 0;
    edit.setDataInvalid(true);
    try std.testing.expectEqual(@as(usize, 1), events.testing_property_changes);
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&edit.base, constants.UIA_IsDataValidForFormPropertyId, &value));
    try std.testing.expectEqual(@as(i16, com.VARIANT_FALSE), value.value.bool_val);
    edit.setDataInvalid(true);
    try std.testing.expectEqual(@as(usize, 1), events.testing_property_changes);

    edit.setDataInvalid(false);
    try std.testing.expectEqual(@as(usize, 2), events.testing_property_changes);
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&edit.base, constants.UIA_IsDataValidForFormPropertyId, &value));
    try std.testing.expectEqual(@as(i16, com.VARIANT_TRUE), value.value.bool_val);

    // Text and buttons are not form fields.
    const button = try SettingsControlProvider.create(std.testing.allocator, hwnd, .button, "Save");
    defer _ = SettingsControlProvider.Release(&button.base);
    value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&button.base, constants.UIA_IsDataValidForFormPropertyId, &value));
    try std.testing.expectEqual(@as(u16, com.VT_EMPTY), value.vt);
}

test "SettingsControlProvider says a field differs from its default as ItemStatus" {
    const hwnd = try settings_provider_windows.create("EDIT");
    defer _ = settings_provider_windows.DestroyWindow(hwnd);
    const edit = try SettingsControlProvider.create(std.testing.allocator, hwnd, .edit, "Font size");
    defer _ = SettingsControlProvider.Release(&edit.base);

    events.testing_property_changes = 0;
    try expectBstrProperty(&edit.base, constants.UIA_ItemStatusPropertyId, "");
    edit.setChangedFromDefault(true);
    // A change is announced once; the same state again is not.
    try std.testing.expectEqual(@as(usize, 1), events.testing_property_changes);
    edit.setChangedFromDefault(true);
    try std.testing.expectEqual(@as(usize, 1), events.testing_property_changes);
    try expectBstrProperty(&edit.base, constants.UIA_ItemStatusPropertyId, SettingsControlProvider.changed_from_default_status);
    // The name a harness and voice control find the field by does not change.
    try expectBstrProperty(&edit.base, constants.UIA_NamePropertyId, "Font size");
    edit.setChangedFromDefault(false);
    try std.testing.expectEqual(@as(usize, 2), events.testing_property_changes);
    try expectBstrProperty(&edit.base, constants.UIA_ItemStatusPropertyId, "");

    // A button is not a field and has no status.
    const button = try SettingsControlProvider.create(std.testing.allocator, hwnd, .button, "Reset Font size");
    defer _ = SettingsControlProvider.Release(&button.base);
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, SettingsControlProvider.GetPropertyValue(&button.base, constants.UIA_ItemStatusPropertyId, &value));
    try std.testing.expectEqual(@as(u16, com.VT_EMPTY), value.vt);
}

test "SettingsSectionProvider reports what its section holds as ItemStatus" {
    const hwnd = try settings_provider_windows.create("BUTTON");
    defer _ = settings_provider_windows.DestroyWindow(hwnd);
    const group = try SettingsSectionGroupProvider.create(std.testing.allocator, hwnd);
    const section = try SettingsSectionProvider.create(std.testing.allocator, hwnd, "Appearance", 0, group);
    group.setSection(0, section);
    defer {
        group.detach();
        section.detach();
        _ = SettingsSectionProvider.Release(&section.base);
        _ = SettingsSectionGroupProvider.Release(&group.base);
    }

    events.testing_property_changes = 0;
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "");
    section.setMarker(.unsaved);
    // A new status is announced once; the same one again is not.
    try std.testing.expectEqual(@as(usize, 1), events.testing_property_changes);
    section.setMarker(.unsaved);
    try std.testing.expectEqual(@as(usize, 1), events.testing_property_changes);
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "Has unsaved changes");
    section.setMarker(.invalid);
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "Has an invalid value");
    try std.testing.expectEqual(SettingsSectionMarker.invalid, section.markerState());
    // The name a harness finds the rail button by does not change.
    try expectBstrProperty(&section.base, constants.UIA_NamePropertyId, "Appearance");
    section.setMarker(.none);
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "");
}

test "SettingsSectionProvider says how many settings a search found on its page" {
    const hwnd = try settings_provider_windows.create("BUTTON");
    defer _ = settings_provider_windows.DestroyWindow(hwnd);
    const group = try SettingsSectionGroupProvider.create(std.testing.allocator, hwnd);
    const section = try SettingsSectionProvider.create(std.testing.allocator, hwnd, "Privacy", 0, group);
    group.setSection(0, section);
    defer {
        group.detach();
        section.detach();
        _ = SettingsSectionProvider.Release(&section.base);
        _ = SettingsSectionGroupProvider.Release(&group.base);
    }

    events.testing_property_changes = 0;
    section.setSearchCount(3);
    try std.testing.expectEqual(@as(usize, 1), events.testing_property_changes);
    // The same count again is not announced.
    section.setSearchCount(3);
    try std.testing.expectEqual(@as(usize, 1), events.testing_property_changes);
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "3 settings found");
    section.setSearchCount(1);
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "1 setting found");
    section.setSearchCount(0);
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "no settings found");
    // After what the section holds.
    section.setMarker(.invalid);
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "Has an invalid value, no settings found");
    // No search: the section's own status alone.
    section.setSearchCount(null);
    try expectBstrProperty(&section.base, constants.UIA_ItemStatusPropertyId, "Has an invalid value");
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
            return .{
                .document_text = document_text,
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
