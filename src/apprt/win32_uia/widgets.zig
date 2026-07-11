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
//!     ControlType=Document and exposes the plain terminal buffer
//!     through the read-only Value pattern.
//!
//! Item-level providers (`IRawElementProviderFragment` hierarchy, per-
//! row `ISelectionItemProvider`) are planned but not in this pass —
//! they require significantly more surface (runtime-ids, navigation,
//! bounding rects). The widget-level provider is the floor that keeps
//! us honest about the mandate.

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
};

pub const PaletteListProvider = struct {
    base: com.IRawElementProviderSimple,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state: PaletteListState,
    detached: std.atomic.Value(bool),

    const vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = PaletteListProvider.QueryInterface,
        .AddRef = PaletteListProvider.AddRef,
        .Release = PaletteListProvider.Release,
        .get_ProviderOptions = PaletteListProvider.get_ProviderOptions,
        .GetPatternProvider = PaletteListProvider.GetPatternProvider,
        .GetPropertyValue = PaletteListProvider.GetPropertyValue,
        .get_HostRawElementProvider = PaletteListProvider.get_HostRawElementProvider,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        state: PaletteListState,
    ) !*PaletteListProvider {
        const self = try alloc.create(PaletteListProvider);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .state = state,
            .detached = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Disconnect from the widget before its owner is freed. UIA clients may
    /// retain COM references beyond HWND teardown.
    pub fn detach(self: *PaletteListProvider) void {
        self.detached.store(true, .release);
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *PaletteListProvider {
        return @fieldParentPtr("base", p);
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
        _: *com.IRawElementProviderSimple,
        _: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
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
                const bstr = allocBstrFromUtf8(self.alloc, text);
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_LocalizedControlTypePropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("command palette matches");
                out.* = com.VARIANT.fromBstr(com.SysAllocString(literal));
            },
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                out.* = com.VARIANT.fromBstr(com.SysAllocString(literal));
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            constants.UIA_IsEnabledPropertyId,
            constants.UIA_IsKeyboardFocusablePropertyId,
            => out.* = com.VARIANT.fromBool(true),
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
};

pub const TerminalProvider = struct {
    base: com.IRawElementProviderSimple,
    value_iface: com.IValueProvider,
    text_iface: com.ITextProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state: TerminalState,
    detached: std.atomic.Value(bool),

    const simple_vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = TerminalProvider.QueryInterface,
        .AddRef = TerminalProvider.AddRef,
        .Release = TerminalProvider.Release,
        .get_ProviderOptions = TerminalProvider.get_ProviderOptions,
        .GetPatternProvider = TerminalProvider.GetPatternProvider,
        .GetPropertyValue = TerminalProvider.GetPropertyValue,
        .get_HostRawElementProvider = TerminalProvider.get_HostRawElementProvider,
    };

    const value_vtbl: com.IValueProviderVtbl = .{
        .QueryInterface = TerminalProvider.ValueQueryInterface,
        .AddRef = TerminalProvider.ValueAddRef,
        .Release = TerminalProvider.ValueRelease,
        .SetValue = TerminalProvider.SetValue,
        .get_Value = TerminalProvider.get_Value,
        .get_IsReadOnly = TerminalProvider.get_IsReadOnly,
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
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .state = state,
            .detached = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Disconnect from the HWND before its owner is destroyed. UIA clients
    /// may retain COM references beyond terminal window teardown.
    pub fn detach(self: *TerminalProvider) void {
        self.detached.store(true, .release);
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

    pub fn QueryInterface(
        self_base: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        return self.queryInterface(iid, out);
    }

    fn ValueQueryInterface(
        self_value: *com.IValueProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(self_value);
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
        if (iidEqual(iid, &com.IID_IValueProvider)) {
            out.* = @ptrCast(&self.value_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        if (iidEqual(iid, &com.IID_ITextProvider)) {
            out.* = @ptrCast(&self.text_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
            return com.S_OK;
        }
        return com.E_NOINTERFACE;
    }

    pub fn AddRef(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn ValueAddRef(self_value: *com.IValueProvider) callconv(.winapi) u32 {
        const self = fromValue(self_value);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn TextAddRef(self_text: *com.ITextProvider) callconv(.winapi) u32 {
        const self = fromText(self_text);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    pub fn Release(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        return self.release();
    }

    fn ValueRelease(self_value: *com.IValueProvider) callconv(.winapi) u32 {
        const self = fromValue(self_value);
        return self.release();
    }

    fn TextRelease(self_text: *com.ITextProvider) callconv(.winapi) u32 {
        const self = fromText(self_text);
        return self.release();
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
        if (pattern_id == constants.UIA_ValuePatternId) {
            out.* = @ptrCast(&self.value_iface);
            _ = self.refcount.fetchAdd(1, .monotonic);
        } else if (pattern_id == constants.UIA_TextPatternId) {
            out.* = @ptrCast(&self.text_iface);
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

        switch (prop_id) {
            constants.UIA_ControlTypePropertyId => {
                out.* = com.VARIANT.fromI4(constants.UIA_DocumentControlTypeId);
            },
            constants.UIA_NamePropertyId => {
                var buf: [256]u8 = undefined;
                const name = self.state.name(self.state.ctx, &buf);
                out.* = com.VARIANT.fromBstr(allocBstrFromUtf8(self.alloc, name));
            },
            constants.UIA_LocalizedControlTypePropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("terminal");
                out.* = com.VARIANT.fromBstr(com.SysAllocString(literal));
            },
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                out.* = com.VARIANT.fromBstr(com.SysAllocString(literal));
            },
            constants.UIA_HelpTextPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Read-only terminal text");
                const bstr = com.SysAllocString(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_ValueValuePropertyId => {
                const bstr = self.allocValueBstr() orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_ValueIsReadOnlyPropertyId => {
                out.* = com.VARIANT.fromBool(true);
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

    fn SetValue(
        _: *com.IValueProvider,
        _: [*:0]const u16,
    ) callconv(.winapi) com.HRESULT {
        return com.E_NOTIMPL;
    }

    fn get_Value(
        self_value: *com.IValueProvider,
        out: *?[*:0]u16,
    ) callconv(.winapi) com.HRESULT {
        const self = fromValue(self_value);
        out.* = self.allocValueBstr() orelse return com.E_OUTOFMEMORY;
        return com.S_OK;
    }

    fn get_IsReadOnly(
        _: *com.IValueProvider,
        out: *com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        out.* = 1;
        return com.S_OK;
    }

    fn allocValueBstr(self: *TerminalProvider) ?[*:0]u16 {
        const text = self.state.value(self.state.ctx, self.alloc) catch |err| {
            std.log.warn("uia: TerminalProvider value snapshot failed err={}", .{err});
            return allocBstrFromUtf8(self.alloc, "");
        };
        defer self.alloc.free(text);
        return allocBstrFromUtf8(self.alloc, text);
    }

    fn GetSelection(
        _: *com.ITextProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.SafeArrayCreateVector(com.VT_UNKNOWN, 0, 0);
        return if (out.* == null) com.E_OUTOFMEMORY else com.S_OK;
    }

    fn GetVisibleRanges(
        self_text: *com.ITextProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromText(self_text);
        return self.singleVisibleRangeArray(out);
    }

    fn RangeFromChild(
        _: *com.ITextProvider,
        _: ?*com.IRawElementProviderSimple,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
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
        _: *com.ITextProvider,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.SupportedTextSelection_None;
        return com.S_OK;
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
        const terminal_snapshot = self.terminalSnapshot() catch return com.E_OUTOFMEMORY;
        defer self.alloc.free(terminal_snapshot.visible_text);

        const document_text = terminal_snapshot.document_text;
        var document_text_owned = true;
        defer if (document_text_owned) self.alloc.free(document_text);

        document_text_owned = false;
        return self.createRangeFromText(document_text, terminal_snapshot.visible_range, out);
    }

    fn createDocumentRange(
        self: *TerminalProvider,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        out.* = null;
        const text = self.state.value(self.state.ctx, self.alloc) catch |err| {
            std.log.warn("uia: TerminalProvider text snapshot failed err={}", .{err});
            return com.E_OUTOFMEMORY;
        };

        return self.createRangeFromText(text, .{ .start = 0, .end = text.len }, out);
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
        const terminal_snapshot = self.terminalSnapshot() catch return com.E_OUTOFMEMORY;
        defer self.alloc.free(terminal_snapshot.visible_text);

        const document_text = terminal_snapshot.document_text;
        var document_text_owned = true;
        defer if (document_text_owned) self.alloc.free(document_text);

        const visible_offset = self.byteOffsetForScreenPoint(terminal_snapshot.visible_text, point);
        const document_offset = visibleOffsetToDocumentOffset(document_text, terminal_snapshot.visible_range, visible_offset);
        document_text_owned = false;
        const hr = self.createRangeFromText(document_text, .{ .start = document_offset, .end = document_offset }, out);
        return hr;
    }

    fn visibleText(self: *TerminalProvider) ![]u8 {
        const value_fn = self.state.visible_value orelse self.state.value;
        return value_fn(self.state.ctx, self.alloc) catch |err| {
            std.log.warn("uia: TerminalProvider visible text snapshot failed err={}", .{err});
            return err;
        };
    }

    fn terminalSnapshot(self: *TerminalProvider) !TerminalSnapshot {
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
            };
        };

        errdefer self.alloc.free(raw_snapshot.document_text);
        errdefer self.alloc.free(raw_snapshot.visible_text);

        const start = @min(raw_snapshot.visible_range.start, raw_snapshot.document_text.len);
        const end = @min(@max(start, raw_snapshot.visible_range.end), raw_snapshot.document_text.len);
        return .{
            .document_text = raw_snapshot.document_text,
            .visible_text = raw_snapshot.visible_text,
            .visible_range = .{ .start = start, .end = end },
        };
    }

    fn byteOffsetForScreenPoint(self: *TerminalProvider, text: []const u8, point: com.UiaPoint) usize {
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
            return 0;
        }

        return byteOffsetForClientPoint(text, client_rect, client_point);
    }

    fn createRangeFromText(
        self: *TerminalProvider,
        text: []u8,
        range_offsets: terminal_text.OffsetRange,
        out: *?*com.ITextRangeProvider,
    ) com.HRESULT {
        const range = TerminalTextRangeProvider.create(
            self.alloc,
            self,
            text,
            range_offsets,
        ) catch |err| {
            std.log.warn("uia: TerminalTextRangeProvider.create failed err={}", .{err});
            self.alloc.free(text);
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
    text: []u8,
    range: terminal_text.OffsetRange,

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

    fn create(
        alloc: std.mem.Allocator,
        parent: *TerminalProvider,
        text: []u8,
        range: terminal_text.OffsetRange,
    ) !*TerminalTextRangeProvider {
        const self = try alloc.create(TerminalTextRangeProvider);
        _ = TerminalProvider.AddRef(&parent.base);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .parent = parent,
            .text = text,
            .range = normalizeRange(range, text.len),
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
            self.alloc.free(self.text);
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
        const text_copy = self.alloc.dupe(u8, self.text) catch return com.E_OUTOFMEMORY;
        const clone = create(self.alloc, self.parent, text_copy, self.range) catch {
            self.alloc.free(text_copy);
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
        self.range = switch (unit) {
            com.TextUnit_Character => characterByteRange(self.text, self.range.start),
            com.TextUnit_Word, com.TextUnit_Format => wordByteRange(self.text, self.range.start),
            com.TextUnit_Line => lineByteRangeForOffset(self.text, self.range.start),
            com.TextUnit_Paragraph, com.TextUnit_Page, com.TextUnit_Document => .{ .start = 0, .end = self.text.len },
            else => return com.E_INVALIDARG,
        };
        return com.S_OK;
    }

    fn FindAttribute(
        _: *com.ITextRangeProvider,
        _: i32,
        _: com.VARIANT,
        _: com.BOOL,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }

    fn FindText(
        _: *com.ITextRangeProvider,
        _: ?[*:0]const u16,
        _: com.BOOL,
        _: com.BOOL,
        out: *?*com.ITextRangeProvider,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.E_NOTIMPL;
    }

    fn GetAttributeValue(
        _: *com.ITextRangeProvider,
        _: i32,
        out: *com.VARIANT,
    ) callconv(.winapi) com.HRESULT {
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
        _: *com.ITextRangeProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.SafeArrayCreateVector(com.VT_R8, 0, 0);
        return if (out.* == null) com.E_OUTOFMEMORY else com.S_OK;
    }

    fn GetEnclosingElement(
        self_base: *com.ITextRangeProvider,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
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
        out.* = allocBstrFromUtf8Max(
            self.alloc,
            self.text[self.range.start..self.range.end],
            max_length,
        ) orelse return com.E_OUTOFMEMORY;
        return com.S_OK;
    }

    fn Move(
        _: *com.ITextRangeProvider,
        _: i32,
        _: i32,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = 0;
        return com.E_NOTIMPL;
    }

    fn MoveEndpointByUnit(
        _: *com.ITextRangeProvider,
        _: i32,
        _: i32,
        _: i32,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = 0;
        return com.E_NOTIMPL;
    }

    fn MoveEndpointByRange(
        _: *com.ITextRangeProvider,
        _: i32,
        _: ?*com.ITextRangeProvider,
        _: i32,
    ) callconv(.winapi) com.HRESULT {
        return com.E_NOTIMPL;
    }

    fn Select(_: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return com.E_NOTIMPL;
    }

    fn AddToSelection(_: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return com.E_NOTIMPL;
    }

    fn RemoveFromSelection(_: *com.ITextRangeProvider) callconv(.winapi) com.HRESULT {
        return com.E_NOTIMPL;
    }

    fn ScrollIntoView(
        _: *com.ITextRangeProvider,
        _: com.BOOL,
    ) callconv(.winapi) com.HRESULT {
        return com.S_OK;
    }

    fn GetChildren(
        _: *com.ITextRangeProvider,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
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

fn countTextLines(text: []const u8) usize {
    var count: usize = 1;
    for (text, 0..) |c, i| {
        if (c == '\n' and i + 1 < text.len) count += 1;
    }
    return count;
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

test "TerminalProvider QueryInterface accepts ValueProvider" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?*anyopaque = null;
    const hr = TerminalProvider.QueryInterface(&p.base, &com.IID_IValueProvider, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    _ = TerminalProvider.ValueRelease(@ptrCast(@alignCast(out.?)));
}

test "TerminalProvider exposes Value pattern provider" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?*com.IUnknown = null;
    const hr = TerminalProvider.GetPatternProvider(&p.base, constants.UIA_ValuePatternId, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    _ = TerminalProvider.ValueRelease(@ptrCast(@alignCast(out.?)));
}

test "TerminalProvider QueryInterface accepts TextProvider" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?*anyopaque = null;
    const hr = TerminalProvider.QueryInterface(&p.base, &com.IID_ITextProvider, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    _ = TerminalProvider.TextRelease(@ptrCast(@alignCast(out.?)));
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
}

test "TerminalProvider refcount and state retain balance across value provider refs" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    try std.testing.expectEqual(@as(u32, 1), state_data.retains);
    try std.testing.expectEqual(@as(u32, 0), state_data.releases);

    var out: ?*com.IUnknown = null;
    try std.testing.expectEqual(
        com.S_OK,
        TerminalProvider.GetPatternProvider(&p.base, constants.UIA_ValuePatternId, &out),
    );
    try std.testing.expect(out != null);
    try std.testing.expectEqual(@as(u32, 3), TerminalProvider.AddRef(&p.base));
    try std.testing.expectEqual(@as(u32, 2), TerminalProvider.Release(&p.base));
    try std.testing.expectEqual(@as(u32, 1), TerminalProvider.ValueRelease(@ptrCast(@alignCast(out.?))));
    try std.testing.expectEqual(@as(u32, 0), TerminalProvider.Release(&p.base));
    try std.testing.expectEqual(@as(u32, 1), state_data.retains);
    try std.testing.expectEqual(@as(u32, 1), state_data.releases);
}

test "TerminalProvider text provider reports no selectable text" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var selection: i32 = -1;
    const hr = TerminalProvider.get_SupportedTextSelection(&p.text_iface, &selection);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(com.SupportedTextSelection_None, selection);
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

test "TerminalProvider get_Value returns non-null BSTR" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?[*:0]u16 = null;
    const hr = TerminalProvider.get_Value(&p.value_iface, &out);
    defer com.SysFreeString(out);

    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    try std.testing.expectEqual(@as(u32, 11), com.SysStringLen(out));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("hello\nworld"), out.?[0..11]);
    try std.testing.expectEqual(@as(u32, 1), state_data.value_calls);
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

    var same: com.BOOL = 0;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.Compare(range.?, clone, &same));
    try std.testing.expectEqual(@as(com.BOOL, 1), same);

    var enclosing: ?*com.IRawElementProviderSimple = null;
    try std.testing.expectEqual(com.S_OK, TerminalTextRangeProvider.GetEnclosingElement(clone.?, &enclosing));
    try std.testing.expect(enclosing != null);
    try std.testing.expectEqual(@as(u32, 3), TerminalProvider.Release(enclosing.?));
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
    var range_provider = try TerminalTextRangeProvider.create(
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

test "TerminalProvider ValueValueProperty returns non-null BSTR" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var value = com.VARIANT.empty();
    const hr = TerminalProvider.GetPropertyValue(&p.base, constants.UIA_ValueValuePropertyId, &value);
    defer com.SysFreeString(value.value.bstr);

    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(com.VT_BSTR, value.vt);
    try std.testing.expect(value.value.bstr != null);
    try std.testing.expectEqual(@as(u32, 11), com.SysStringLen(value.value.bstr));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("hello\nworld"), value.value.bstr.?[0..11]);
    try std.testing.expectEqual(@as(u32, 1), state_data.value_calls);
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

test "TerminalProvider value allocation failure returns E_OUTOFMEMORY" {
    var state_data = TestTerminalStateData{};
    const state = testTerminalState(&state_data);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?[*:0]u16 = null;
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
        const original_alloc = p.alloc;
        p.alloc = failing.allocator();
        defer p.alloc = original_alloc;

        const get_value_hr = TerminalProvider.get_Value(&p.value_iface, &out);
        try std.testing.expectEqual(com.E_OUTOFMEMORY, get_value_hr);
        try std.testing.expect(out == null);
    }

    var value = com.VARIANT.empty();
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
        const original_alloc = p.alloc;
        p.alloc = failing.allocator();
        defer p.alloc = original_alloc;

        const prop_hr = TerminalProvider.GetPropertyValue(&p.base, constants.UIA_ValueValuePropertyId, &value);
        try std.testing.expectEqual(com.E_OUTOFMEMORY, prop_hr);
        try std.testing.expectEqual(com.VT_EMPTY, value.vt);
    }
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

    var host: ?*com.IRawElementProviderSimple = undefined;
    const hr = TerminalProvider.get_HostRawElementProvider(&provider.base, &host);
    try std.testing.expectEqual(@as(com.HRESULT, @bitCast(@as(u32, 0x80040201))), hr);
    try std.testing.expectEqual(@as(?*com.IRawElementProviderSimple, null), host);
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
