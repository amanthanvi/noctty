//! Root `IRawElementProviderSimple` for the noctty host HWND.
//!
//! Returned from `WM_GETOBJECT` when the client asks for
//! `UiaRootObjectId`. Reports:
//!   * `UIA_NamePropertyId`            = live window title
//!   * `UIA_ControlTypePropertyId`     = UIA_WindowControlTypeId
//!   * `UIA_LocalizedControlTypePropertyId` = "terminal window"
//!   * `UIA_IsKeyboardFocusablePropertyId`  = false (focus lives on panes)
//!   * `UIA_HasKeyboardFocusPropertyId`     = false
//!   * `UIA_IsEnabledPropertyId`            = true
//!   * `UIA_IsControlElementPropertyId`     = true
//!   * `UIA_FrameworkIdPropertyId`          = "Win32"
//!
//! BSTR ownership: `GetPropertyValue` hands a BSTR to the caller who
//! will `VariantClear` (which `SysFreeString`s it). We must allocate a
//! fresh BSTR per call — caching pointers and handing the same one
//! back twice produces a use-after-free the second time and a
//! double-free when we try to free our "cached" pointer too.
//!
//! `get_HostRawElementProvider` chains to `UiaHostProviderFromHwnd` so
//! the system's default provider is merged in — that is what lets
//! Narrator pick up `Minimize/Maximize/Close` caption-button focus out
//! of the box even before we ship the integrated titlebar.

const std = @import("std");
const com = @import("com.zig");
const constants = @import("constants.zig");

pub const RootProvider = struct {
    // COM interface shape MUST be first so &self.base == &self (COM layout).
    base: com.IRawElementProviderSimple,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    detached: std.atomic.Value(bool),
    disconnected: std.atomic.Value(bool),

    /// The singleton vtable pointer. All RootProvider instances share it.
    const vtbl: com.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = RootProvider.QueryInterface,
        .AddRef = RootProvider.AddRef,
        .Release = RootProvider.Release,
        .get_ProviderOptions = RootProvider.get_ProviderOptions,
        .GetPatternProvider = RootProvider.GetPatternProvider,
        .GetPropertyValue = RootProvider.GetPropertyValue,
        .get_HostRawElementProvider = RootProvider.get_HostRawElementProvider,
    };

    pub fn create(alloc: std.mem.Allocator, hwnd: com.HWND) !*RootProvider {
        const self = try alloc.create(RootProvider);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    pub fn detach(self: *RootProvider) void {
        self.detached.store(true, .release);
    }

    pub fn disconnect(self: *RootProvider) com.HRESULT {
        self.detach();
        if (self.disconnected.load(.acquire)) return com.S_OK;
        const hr = com.UiaDisconnectProvider(&self.base);
        if (hr == com.S_OK) {
            self.disconnected.store(true, .release);
        }
        return hr;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *RootProvider {
        return @fieldParentPtr("base", p);
    }

    /// Allocate a BSTR copy of `literal` for a per-call property return.
    fn allocBstrFromLiteral(literal: [*:0]const u16) ?[*:0]u16 {
        return com.SysAllocString(literal);
    }

    /// Allocate a BSTR for the current HWND title, or a "noctty"
    /// fallback if the title is empty or the query fails. Runs per
    /// property query — caching is unsafe because the caller frees.
    fn allocNameBstr(self: *RootProvider) ?[*:0]u16 {
        const fallback = std.unicode.utf8ToUtf16LeStringLiteral("noctty");
        const len = com.GetWindowTextLengthW(self.hwnd);
        if (len <= 0) return com.SysAllocString(fallback);

        // GetWindowTextLengthW returns chars excluding the null
        // terminator; allocate len+1 u16s + a sentinel slot.
        const size: usize = @intCast(len);
        const buf = self.alloc.allocSentinel(u16, size, 0) catch
            return com.SysAllocString(fallback);
        defer self.alloc.free(buf);
        const copied = com.GetWindowTextW(self.hwnd, buf.ptr, @intCast(size + 1));
        if (copied <= 0) return com.SysAllocString(fallback);
        buf[@intCast(copied)] = 0;
        return com.SysAllocString(@ptrCast(buf.ptr));
    }

    // ── IUnknown ────────────────────────────────────────────────────────

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

    // ── IRawElementProviderSimple ───────────────────────────────────────

    fn get_ProviderOptions(
        _: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider;
        return com.S_OK;
    }

    fn GetPatternProvider(
        self_base: *com.IRawElementProviderSimple,
        _: i32,
        out: *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT {
        // No control patterns are exposed. Per the UIA contract, return
        // S_OK with out=null rather than E_NOTIMPL.
        out.* = null;
        if (fromBase(self_base).detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
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
                out.* = com.VARIANT.fromI4(constants.UIA_WindowControlTypeId);
            },
            constants.UIA_NamePropertyId => {
                const bstr = self.allocNameBstr() orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_LocalizedControlTypePropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("terminal window");
                const bstr = allocBstrFromLiteral(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_FrameworkIdPropertyId => {
                const literal = std.unicode.utf8ToUtf16LeStringLiteral("Win32");
                const bstr = allocBstrFromLiteral(literal) orelse return com.E_OUTOFMEMORY;
                out.* = com.VARIANT.fromBstr(bstr);
            },
            constants.UIA_IsControlElementPropertyId,
            constants.UIA_IsContentElementPropertyId,
            constants.UIA_IsEnabledPropertyId,
            => out.* = com.VARIANT.fromBool(true),
            constants.UIA_IsKeyboardFocusablePropertyId,
            constants.UIA_HasKeyboardFocusPropertyId,
            => out.* = com.VARIANT.fromBool(false),
            else => {
                // Unreported property: empty VARIANT + S_OK is the correct
                // UIA contract; do NOT return E_NOTIMPL.
            },
        }
        return com.S_OK;
    }

    fn get_HostRawElementProvider(
        self_base: *com.IRawElementProviderSimple,
        out: *?*com.IRawElementProviderSimple,
    ) callconv(.winapi) com.HRESULT {
        const self = fromBase(self_base);
        out.* = null;
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        // Chain the system's default provider so the caption buttons,
        // system menu, and window-level accessibility tree come through
        // unchanged. We do NOT hold onto the returned provider — the
        // client does.
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }
};

fn iidEqual(a: *const com.GUID, b: *const com.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

pub fn returnProvider(
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
    provider: *RootProvider,
) ?com.LRESULT {
    if (lParam != com.UiaRootObjectId) return null;
    if (provider.detached.load(.acquire)) return null;
    return com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
}

test "RootProvider create / release balances refcount" {
    // We can't call the real Win32 `UiaHostProviderFromHwnd` inside a
    // unit test, but we can exercise create/AddRef/Release directly.
    var rp = try RootProvider.create(std.testing.allocator, @ptrFromInt(0x1));
    // Initial refcount 1 after create.
    try std.testing.expectEqual(@as(u32, 2), RootProvider.AddRef(&rp.base));
    try std.testing.expectEqual(@as(u32, 1), RootProvider.Release(&rp.base));
    // Final Release drops to 0 and destroys the instance.
    try std.testing.expectEqual(@as(u32, 0), RootProvider.Release(&rp.base));
}

test "RootProvider QueryInterface returns IRawElementProviderSimple" {
    var rp = try RootProvider.create(std.testing.allocator, @ptrFromInt(0x1));
    defer _ = RootProvider.Release(&rp.base);

    var out: ?*anyopaque = null;
    const hr = RootProvider.QueryInterface(&rp.base, &com.IID_IRawElementProviderSimple, &out);
    try std.testing.expectEqual(com.S_OK, hr);
    try std.testing.expect(out != null);
    // QI returned a new ref — release it.
    _ = RootProvider.Release(&rp.base);
}

test "RootProvider QueryInterface rejects unknown IID" {
    var rp = try RootProvider.create(std.testing.allocator, @ptrFromInt(0x1));
    defer _ = RootProvider.Release(&rp.base);

    const bogus = com.GUID.parse("{DEADBEEF-0000-0000-0000-000000000000}");
    var out: ?*anyopaque = null;
    const hr = RootProvider.QueryInterface(&rp.base, &bogus, &out);
    try std.testing.expectEqual(com.E_NOINTERFACE, hr);
    try std.testing.expect(out == null);
}

test "RootProvider detach is idempotent and rejects late queries" {
    var rp = try RootProvider.create(std.testing.allocator, @ptrFromInt(0x1));
    defer _ = RootProvider.Release(&rp.base);
    rp.detach();
    rp.detach();

    var value = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        RootProvider.GetPropertyValue(&rp.base, constants.UIA_NamePropertyId, &value),
    );
}
