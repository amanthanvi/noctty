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
    name: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
    value: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8,
    focused: *const fn (ctx: *anyopaque) bool,
};

pub const PaletteListProvider = struct {
    base: com.IRawElementProviderSimple,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state: PaletteListState,

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
        };
        return self;
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
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }
};

pub const TerminalProvider = struct {
    base: com.IRawElementProviderSimple,
    value_iface: com.IValueProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    state: TerminalState,

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

    pub fn create(
        alloc: std.mem.Allocator,
        hwnd: com.HWND,
        state: TerminalState,
    ) !*TerminalProvider {
        const self = try alloc.create(TerminalProvider);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .value_iface = .{ .vtbl = &value_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .state = state,
        };
        return self;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *TerminalProvider {
        return @fieldParentPtr("base", p);
    }

    fn fromValue(p: *com.IValueProvider) *TerminalProvider {
        return @fieldParentPtr("value_iface", p);
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

    pub fn Release(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        return self.release();
    }

    fn ValueRelease(self_value: *com.IValueProvider) callconv(.winapi) u32 {
        const self = fromValue(self_value);
        return self.release();
    }

    fn release(self: *TerminalProvider) u32 {
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
        if (pattern_id == constants.UIA_ValuePatternId) {
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
            constants.UIA_ValueValuePropertyId => {
                out.* = com.VARIANT.fromBstr(self.allocValueBstr());
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
        out.* = self.allocValueBstr();
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
    buf[written] = 0;
    return com.SysAllocString(@ptrCast(buf.ptr));
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
    var counter: u32 = 0;
    const state = testTerminalState(&counter);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?*anyopaque = null;
    const hr = TerminalProvider.QueryInterface(&p.base, &com.IID_IValueProvider, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    _ = TerminalProvider.ValueRelease(@ptrCast(@alignCast(out.?)));
}

test "TerminalProvider exposes Value pattern provider" {
    var counter: u32 = 0;
    const state = testTerminalState(&counter);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var out: ?*com.IUnknown = null;
    const hr = TerminalProvider.GetPatternProvider(&p.base, constants.UIA_ValuePatternId, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    _ = TerminalProvider.ValueRelease(@ptrCast(@alignCast(out.?)));
}

test "TerminalProvider reports document control type" {
    var counter: u32 = 0;
    const state = testTerminalState(&counter);

    var p = try TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), state);
    defer _ = TerminalProvider.Release(&p.base);

    var value = com.VARIANT.empty();
    const hr = TerminalProvider.GetPropertyValue(&p.base, constants.UIA_ControlTypePropertyId, &value);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expectEqual(constants.UIA_DocumentControlTypeId, value.value.i4);
}

fn testTerminalState(counter: *u32) TerminalState {
    const callbacks = struct {
        fn name(ctx: *anyopaque, buf: []u8) []const u8 {
            const c: *u32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
            return std.fmt.bufPrint(buf, "terminal {d}", .{c.*}) catch "";
        }

        fn value(ctx: *anyopaque, alloc: std.mem.Allocator) ![]u8 {
            _ = ctx;
            return try alloc.dupe(u8, "hello\nworld");
        }

        fn focused(ctx: *anyopaque) bool {
            _ = ctx;
            return true;
        }
    };
    return .{
        .ctx = @ptrCast(counter),
        .name = callbacks.name,
        .value = callbacks.value,
        .focused = callbacks.focused,
    };
}
