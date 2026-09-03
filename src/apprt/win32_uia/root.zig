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
//! the system's default provider is merged in — that is what carries the
//! stock caption buttons while the window still has a DWM caption.
//!
//! The integrated titlebar removes that caption: the three buttons are
//! painted by us inside the client area and own no HWND, so no host
//! provider can describe them. `CaptionButtonProvider` supplies them as
//! fragment children of this root, which is why the root also implements
//! `IRawElementProviderFragment` / `IRawElementProviderFragmentRoot`
//! once a `CaptionButtonsState` has been installed.

const std = @import("std");
const com = @import("com.zig");
const constants = @import("constants.zig");
const events = @import("events.zig");

/// The three custom-painted caption buttons of the integrated titlebar,
/// in the left-to-right order they are painted.
pub const CaptionButtonKind = enum(i32) {
    minimize = 0,
    maximize = 1,
    close = 2,
};

/// Paint order, and therefore UIA sibling order.
pub const caption_button_order = [_]CaptionButtonKind{ .minimize, .maximize, .close };

/// Discriminates caption-button runtime ids from any other fragment this
/// root may grow later. Only meaningful next to `UiaAppendRuntimeId`,
/// which prefixes the window's own id.
const caption_runtime_id_tag: i32 = 0x6361_7074; // 'capt'

/// UIA Name for a caption button. Only the middle button's name depends
/// on window state: it reads "Restore" while the window is zoomed, the
/// same flip `paintCaptionButtons` makes to its glyph.
pub fn captionButtonName(kind: CaptionButtonKind, zoomed: bool) []const u8 {
    return switch (kind) {
        .minimize => "Minimize",
        .maximize => if (zoomed) "Restore" else "Maximize",
        .close => "Close",
    };
}

/// The same strings as `captionButtonName`, as UTF-16 literals so the
/// BSTR path needs no runtime conversion. A unit test pins the two
/// tables together.
fn captionButtonNameLiteral(kind: CaptionButtonKind, zoomed: bool) [*:0]const u16 {
    return switch (kind) {
        .minimize => std.unicode.utf8ToUtf16LeStringLiteral("Minimize"),
        .maximize => if (zoomed)
            std.unicode.utf8ToUtf16LeStringLiteral("Restore")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Maximize"),
        .close => std.unicode.utf8ToUtf16LeStringLiteral("Close"),
    };
}

/// Live view of the caption buttons owned by the window that created the
/// root provider. Keeps `win32.zig` out of this module, the same way
/// `ChromeControlState` does for the native chrome providers.
pub const CaptionButtonsState = struct {
    ctx: *anyopaque,
    /// Whether the integrated titlebar is currently painting the three
    /// buttons. False removes them from the tree instead of exposing
    /// zero-sized elements no reader can reach.
    painted: *const fn (ctx: *anyopaque) bool,
    /// Screen-space rect of one painted button, or null when it is not
    /// on screen.
    bounds: *const fn (ctx: *anyopaque, kind: CaptionButtonKind) ?com.UiaRect,
    /// Whether the window is zoomed. Drives the maximize/restore name.
    zoomed: *const fn (ctx: *anyopaque) bool,
    /// Post the same `WM_SYSCOMMAND` the mouse path sends for this
    /// button. Returns false when the post failed.
    invoke: *const fn (ctx: *anyopaque, kind: CaptionButtonKind) bool,
    /// The provider was created on a confirmed STA, so UI Automation may
    /// marshal these callbacks back to the owning UI thread. That is what
    /// keeps them off an RPC thread while they read `Host` state.
    use_com_threading: bool = false,
};

pub const RootProvider = struct {
    // COM interface shape MUST be first so &self.base == &self (COM layout).
    base: com.IRawElementProviderSimple,
    fragment: com.IRawElementProviderFragment,
    fragment_root: com.IRawElementProviderFragmentRoot,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    /// Installed by the owner immediately after `create`, before the
    /// provider is published through `UiaReturnRawElementProvider`, so it
    /// is never written again while UIA can read it. Null keeps the root
    /// a plain `IRawElementProviderSimple` with no children.
    caption: ?CaptionButtonsState,
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
    const fragment_vtbl: com.IRawElementProviderFragmentVtbl = .{
        .QueryInterface = RootProvider.FragmentQueryInterface,
        .AddRef = RootProvider.FragmentAddRef,
        .Release = RootProvider.FragmentRelease,
        .Navigate = RootProvider.Navigate,
        .GetRuntimeId = RootProvider.GetRuntimeId,
        .get_BoundingRectangle = RootProvider.GetBoundingRectangle,
        .GetEmbeddedFragmentRoots = RootProvider.GetEmbeddedFragmentRoots,
        .SetFocus = RootProvider.FragmentSetFocus,
        .get_FragmentRoot = RootProvider.GetFragmentRoot,
    };
    const fragment_root_vtbl: com.IRawElementProviderFragmentRootVtbl = .{
        .QueryInterface = RootProvider.FragmentRootQueryInterface,
        .AddRef = RootProvider.FragmentRootAddRef,
        .Release = RootProvider.FragmentRootRelease,
        .ElementProviderFromPoint = RootProvider.ElementProviderFromPoint,
        .GetFocus = RootProvider.FragmentRootGetFocus,
    };

    pub fn create(alloc: std.mem.Allocator, hwnd: com.HWND) !*RootProvider {
        const self = try alloc.create(RootProvider);
        self.* = .{
            .base = .{ .vtbl = &vtbl },
            .fragment = .{ .vtbl = &fragment_vtbl },
            .fragment_root = .{ .vtbl = &fragment_root_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .hwnd = hwnd,
            .caption = null,
            .detached = std.atomic.Value(bool).init(false),
            .disconnected = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Install the caption-button view. Call once, before the provider is
    /// handed to UIA.
    pub fn setCaptionButtons(self: *RootProvider, state: CaptionButtonsState) void {
        self.caption = state;
    }

    /// True only while the integrated titlebar paints the caption
    /// buttons, which is the only condition under which they are in the
    /// tree at all.
    fn captionPainted(self: *const RootProvider) bool {
        if (self.detached.load(.acquire)) return false;
        const caption = self.caption orelse return false;
        return caption.painted(caption.ctx);
    }

    fn captionZoomed(self: *const RootProvider) bool {
        const caption = self.caption orelse return false;
        return caption.zoomed(caption.ctx);
    }

    fn captionBounds(self: *const RootProvider, kind: CaptionButtonKind) ?com.UiaRect {
        const caption = self.caption orelse return null;
        return caption.bounds(caption.ctx, kind);
    }

    /// Create a caption-button child holding a reference on this root.
    /// Returns null only on allocation failure.
    fn createCaptionButton(self: *RootProvider, kind: CaptionButtonKind) ?*CaptionButtonProvider {
        return CaptionButtonProvider.create(self.alloc, self, kind) catch null;
    }

    /// Tell listening clients that a caption button's Name changed. The
    /// zoomed flip (Maximize <-> Restore) is the only thing that changes
    /// one, so the owner calls this from its size handler.
    ///
    /// The child raised on is a fresh COM object; UIA matches it to the
    /// element a client already holds by runtime id, which is stable per
    /// kind.
    /// Tell listening clients that the root's child set changed. The
    /// caption children exist only while the integrated titlebar paints
    /// them, so a client that cached the fragment tree across a titlebar
    /// toggle, a minimize, or a hide would otherwise keep children that
    /// `Navigate` no longer returns.
    pub fn raiseCaptionStructureChanged(self: *RootProvider) void {
        if (self.detached.load(.acquire)) return;
        if (self.caption == null) return;
        events.raiseStructureChanged(&self.base, .children_invalidated, null);
    }

    pub fn raiseCaptionButtonNameChanged(self: *RootProvider, kind: CaptionButtonKind) void {
        if (!self.captionPainted()) return;
        if (!events.clientsAreListening()) return;
        const child = self.createCaptionButton(kind) orelse return;
        defer _ = CaptionButtonProvider.Release(&child.base);
        events.raiseNameChanged(&child.base);
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

    fn fromFragment(p: *com.IRawElementProviderFragment) *RootProvider {
        return @fieldParentPtr("fragment", p);
    }

    fn fromFragmentRoot(p: *com.IRawElementProviderFragmentRoot) *RootProvider {
        return @fieldParentPtr("fragment_root", p);
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

    /// The fragment interfaces exist only once a caption view is
    /// installed. Advertising a fragment root on a window that can never
    /// paint caption buttons would claim children that do not exist.
    fn query(self: *RootProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
        out.* = null;
        if (iidEqual(iid, &com.IID_IUnknown) or
            iidEqual(iid, &com.IID_IRawElementProviderSimple))
        {
            out.* = @ptrCast(&self.base);
        } else if (self.caption != null and iidEqual(iid, &com.IID_IRawElementProviderFragment)) {
            out.* = @ptrCast(&self.fragment);
        } else if (self.caption != null and iidEqual(iid, &com.IID_IRawElementProviderFragmentRoot)) {
            out.* = @ptrCast(&self.fragment_root);
        } else return com.E_NOINTERFACE;
        _ = self.refcount.fetchAdd(1, .monotonic);
        return com.S_OK;
    }

    pub fn QueryInterface(
        self_base: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromBase(self_base).query(iid, out);
    }

    fn FragmentQueryInterface(
        p: *com.IRawElementProviderFragment,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromFragment(p).query(iid, out);
    }

    fn FragmentRootQueryInterface(
        p: *com.IRawElementProviderFragmentRoot,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromFragmentRoot(p).query(iid, out);
    }

    pub fn AddRef(self_base: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        const self = fromBase(self_base);
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }

    fn FragmentAddRef(p: *com.IRawElementProviderFragment) callconv(.winapi) u32 {
        return AddRef(&fromFragment(p).base);
    }

    fn FragmentRootAddRef(p: *com.IRawElementProviderFragmentRoot) callconv(.winapi) u32 {
        return AddRef(&fromFragmentRoot(p).base);
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

    fn FragmentRelease(p: *com.IRawElementProviderFragment) callconv(.winapi) u32 {
        return Release(&fromFragment(p).base);
    }

    fn FragmentRootRelease(p: *com.IRawElementProviderFragmentRoot) callconv(.winapi) u32 {
        return Release(&fromFragmentRoot(p).base);
    }

    // ── IRawElementProviderSimple ───────────────────────────────────────

    fn get_ProviderOptions(
        self_base: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider |
            comThreadingOption(fromBase(self_base).caption);
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
        // Chain the system's default provider so the system menu, the
        // stock caption when the window still has one, and the
        // window-level accessibility tree come through unchanged. We do
        // NOT hold onto the returned provider — the client does.
        return com.UiaHostProviderFromHwnd(self.hwnd, out);
    }

    // ── IRawElementProviderFragment (the window fragment) ───────────────

    /// Children are the caption buttons and nothing else. Parent and
    /// siblings stay null: this fragment is the root of its own tree and
    /// the HWND host provider places it in the window hierarchy.
    pub fn Navigate(
        p: *com.IRawElementProviderFragment,
        direction: i32,
        out: *?*com.IRawElementProviderFragment,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.captionPainted()) return com.S_OK;
        const kind: CaptionButtonKind = switch (direction) {
            com.NavigateDirection_FirstChild => caption_button_order[0],
            com.NavigateDirection_LastChild => caption_button_order[caption_button_order.len - 1],
            else => return com.S_OK,
        };
        const child = self.createCaptionButton(kind) orelse return com.E_OUTOFMEMORY;
        out.* = &child.fragment;
        return com.S_OK;
    }

    /// Null defers to the HWND host provider's runtime id, which is what
    /// a fragment root backed by a real window must do.
    pub fn GetRuntimeId(
        p: *com.IRawElementProviderFragment,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        if (fromFragment(p).detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.S_OK;
    }

    /// Empty for the same reason as `GetRuntimeId`: the host provider
    /// owns the window rect.
    pub fn GetBoundingRectangle(
        p: *com.IRawElementProviderFragment,
        out: *com.UiaRect,
    ) callconv(.winapi) com.HRESULT {
        out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        if (fromFragment(p).detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.S_OK;
    }

    fn GetEmbeddedFragmentRoots(
        _: *com.IRawElementProviderFragment,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }

    /// The root reports `IsKeyboardFocusable = false`; focus lives on the
    /// panes and the chrome HWNDs, so there is nothing honest to do here.
    fn FragmentSetFocus(p: *com.IRawElementProviderFragment) callconv(.winapi) com.HRESULT {
        if (fromFragment(p).detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.E_NOTIMPL;
    }

    fn GetFragmentRoot(
        p: *com.IRawElementProviderFragment,
        out: *?*com.IRawElementProviderFragmentRoot,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        out.* = &self.fragment_root;
        _ = AddRef(&self.base);
        return com.S_OK;
    }

    // ── IRawElementProviderFragmentRoot ────────────────────────────────

    /// Only the caption buttons are hit-testable here. Everything else in
    /// the window is a real HWND the host provider already resolves, so
    /// null is the correct answer rather than a fallback element.
    pub fn ElementProviderFromPoint(
        p: *com.IRawElementProviderFragmentRoot,
        x: f64,
        y: f64,
        out: *?*com.IRawElementProviderFragment,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragmentRoot(p);
        out.* = null;
        if (self.detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!self.captionPainted()) return com.S_OK;
        for (caption_button_order) |kind| {
            const rect = self.captionBounds(kind) orelse continue;
            if (!rectContains(rect, x, y)) continue;
            const child = self.createCaptionButton(kind) orelse return com.E_OUTOFMEMORY;
            out.* = &child.fragment;
            return com.S_OK;
        }
        return com.S_OK;
    }

    /// No caption button is in the focus-region cycle and the root is not
    /// focusable, so this fragment root never owns focus.
    pub fn FragmentRootGetFocus(
        p: *com.IRawElementProviderFragmentRoot,
        out: *?*com.IRawElementProviderFragment,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        if (fromFragmentRoot(p).detached.load(.acquire)) return com.UIA_E_ELEMENTNOTAVAILABLE;
        return com.S_OK;
    }
};

fn comThreadingOption(caption: ?CaptionButtonsState) i32 {
    const state = caption orelse return 0;
    return if (state.use_com_threading) com.ProviderOptions_UseComThreading else 0;
}

fn rectContains(rect: com.UiaRect, x: f64, y: f64) bool {
    return x >= rect.left and x < rect.left + rect.width and
        y >= rect.top and y < rect.top + rect.height;
}

/// One custom-painted caption button, exposed as a fragment child of the
/// host window's root provider. It has no HWND, so it reports no host
/// provider and its identity is its stable runtime id.
///
/// `IsKeyboardFocusable` is false: the element is object-navigable and
/// invokable, but the focus-region cycle (`win32/focus_region.zig`) does
/// not land on it, and claiming otherwise would contradict the focus
/// events a reader actually receives.
pub const CaptionButtonProvider = struct {
    base: com.IRawElementProviderSimple,
    fragment: com.IRawElementProviderFragment,
    invoke_iface: com.IInvokeProvider,
    refcount: std.atomic.Value(u32),
    alloc: std.mem.Allocator,
    parent: *RootProvider,
    kind: CaptionButtonKind,

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
        .SetFocus = CaptionButtonProvider.SetFocus,
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
        parent: *RootProvider,
        kind: CaptionButtonKind,
    ) !*CaptionButtonProvider {
        const self = try alloc.create(CaptionButtonProvider);
        _ = RootProvider.AddRef(&parent.base);
        self.* = .{
            .base = .{ .vtbl = &simple_vtbl },
            .fragment = .{ .vtbl = &fragment_vtbl },
            .invoke_iface = .{ .vtbl = &invoke_vtbl },
            .refcount = std.atomic.Value(u32).init(1),
            .alloc = alloc,
            .parent = parent,
            .kind = kind,
        };
        return self;
    }

    fn fromBase(p: *com.IRawElementProviderSimple) *CaptionButtonProvider {
        return @fieldParentPtr("base", p);
    }
    fn fromFragment(p: *com.IRawElementProviderFragment) *CaptionButtonProvider {
        return @fieldParentPtr("fragment", p);
    }
    fn fromInvoke(p: *com.IInvokeProvider) *CaptionButtonProvider {
        return @fieldParentPtr("invoke_iface", p);
    }

    /// The button exists only while the integrated titlebar paints it.
    fn available(self: *const CaptionButtonProvider) bool {
        return self.parent.captionPainted();
    }

    fn query(self: *CaptionButtonProvider, iid: *const com.GUID, out: *?*anyopaque) com.HRESULT {
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
    pub fn QueryInterface(
        p: *com.IRawElementProviderSimple,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromBase(p).query(iid, out);
    }
    fn FragmentQueryInterface(
        p: *com.IRawElementProviderFragment,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromFragment(p).query(iid, out);
    }
    fn InvokeQueryInterface(
        p: *com.IInvokeProvider,
        iid: *const com.GUID,
        out: *?*anyopaque,
    ) callconv(.winapi) com.HRESULT {
        return fromInvoke(p).query(iid, out);
    }

    fn addRef(self: *CaptionButtonProvider) u32 {
        return self.refcount.fetchAdd(1, .monotonic) + 1;
    }
    pub fn AddRef(p: *com.IRawElementProviderSimple) callconv(.winapi) u32 {
        return fromBase(p).addRef();
    }
    fn FragmentAddRef(p: *com.IRawElementProviderFragment) callconv(.winapi) u32 {
        return fromFragment(p).addRef();
    }
    fn InvokeAddRef(p: *com.IInvokeProvider) callconv(.winapi) u32 {
        return fromInvoke(p).addRef();
    }

    fn release(self: *CaptionButtonProvider) u32 {
        const previous = self.refcount.fetchSub(1, .acq_rel);
        if (previous == 1) {
            const parent = self.parent;
            self.alloc.destroy(self);
            _ = RootProvider.Release(&parent.base);
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
    fn InvokeRelease(p: *com.IInvokeProvider) callconv(.winapi) u32 {
        return fromInvoke(p).release();
    }

    fn get_ProviderOptions(
        p: *com.IRawElementProviderSimple,
        out: *i32,
    ) callconv(.winapi) com.HRESULT {
        out.* = com.ProviderOptions_ServerSideProvider |
            comThreadingOption(fromBase(p).parent.caption);
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
        _ = self.addRef();
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
                const literal = captionButtonNameLiteral(self.kind, self.parent.captionZoomed());
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
            constants.UIA_IsKeyboardFocusablePropertyId,
            constants.UIA_HasKeyboardFocusPropertyId,
            => out.* = com.VARIANT.fromBool(false),
            constants.UIA_IsOffscreenPropertyId => {
                out.* = com.VARIANT.fromBool(self.parent.captionBounds(self.kind) == null);
            },
            else => {},
        }
        return com.S_OK;
    }

    /// No HWND backs this element, so there is no host provider to chain.
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
            _ = RootProvider.AddRef(&self.parent.base);
            return com.S_OK;
        }
        const ordinal: i32 = @intFromEnum(self.kind);
        const sibling: i32 = switch (direction) {
            com.NavigateDirection_NextSibling => ordinal + 1,
            com.NavigateDirection_PreviousSibling => ordinal - 1,
            else => return com.S_OK,
        };
        if (sibling < 0 or sibling >= caption_button_order.len) return com.S_OK;
        const child = self.parent.createCaptionButton(
            caption_button_order[@intCast(sibling)],
        ) orelse return com.E_OUTOFMEMORY;
        out.* = &child.fragment;
        return com.S_OK;
    }

    /// `UiaAppendRuntimeId` prefixes the window's own id, so the tag plus
    /// the kind identifies the button across queries — which is what lets
    /// a Name event raised on a fresh instance land on the element a
    /// client already holds.
    pub fn GetRuntimeId(
        p: *com.IRawElementProviderFragment,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = null;
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const array = com.SafeArrayCreateVector(com.VT_I4, 0, 3) orelse return com.E_OUTOFMEMORY;
        var values = [_]i32{ com.UiaAppendRuntimeId, caption_runtime_id_tag, @intFromEnum(self.kind) };
        for (&values, 0..) |*value, slot| {
            var index: i32 = @intCast(slot);
            if (com.SafeArrayPutElement(array, &index, value) != com.S_OK) {
                _ = com.SafeArrayDestroy(array);
                return com.E_OUTOFMEMORY;
            }
        }
        out.* = array;
        return com.S_OK;
    }

    pub fn GetBoundingRectangle(
        p: *com.IRawElementProviderFragment,
        out: *com.UiaRect,
    ) callconv(.winapi) com.HRESULT {
        const self = fromFragment(p);
        out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (self.parent.captionBounds(self.kind)) |rect| out.* = rect;
        return com.S_OK;
    }

    fn GetEmbeddedFragmentRoots(
        _: *com.IRawElementProviderFragment,
        out: *?*com.SAFEARRAY,
    ) callconv(.winapi) com.HRESULT {
        out.* = null;
        return com.S_OK;
    }

    /// Caption buttons are deliberately outside the focus-region cycle in
    /// this revision and `IsKeyboardFocusable` says so. Moving real Win32
    /// focus here would contradict that.
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
        _ = RootProvider.AddRef(&self.parent.base);
        return com.S_OK;
    }

    /// Posts the same `WM_SYSCOMMAND` the `WM_NCLBUTTONDOWN` /
    /// `WM_NCLBUTTONUP` path sends for this button. Posting rather than
    /// sending keeps a UIA client off the window's message loop while a
    /// modal size or close command runs.
    pub fn Invoke(p: *com.IInvokeProvider) callconv(.winapi) com.HRESULT {
        const self = fromInvoke(p);
        if (!self.available()) return com.UIA_E_ELEMENTNOTAVAILABLE;
        const caption = self.parent.caption orelse return com.UIA_E_ELEMENTNOTAVAILABLE;
        if (!caption.invoke(caption.ctx, self.kind)) return com.UIA_E_INVALIDOPERATION;
        // Raised only once the command is actually on the window's queue,
        // and before returning, which is where UIA expects it.
        events.raiseInvoked(&self.base);
        return com.S_OK;
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

/// Stand-in for the `Host` view the window installs in production.
const TestCaption = struct {
    painted: bool = true,
    zoomed: bool = false,
    offscreen: bool = false,
    invoke_ok: bool = true,
    invoked: ?CaptionButtonKind = null,
    invoke_count: usize = 0,

    fn fromCtx(ctx: *anyopaque) *TestCaption {
        return @ptrCast(@alignCast(ctx));
    }
    fn paintedFn(ctx: *anyopaque) bool {
        return fromCtx(ctx).painted;
    }
    fn zoomedFn(ctx: *anyopaque) bool {
        return fromCtx(ctx).zoomed;
    }
    /// 46x40 buttons laid out left to right from x=100, y=8, matching the
    /// order `paintCaptionButtons` paints them in.
    fn boundsFn(ctx: *anyopaque, kind: CaptionButtonKind) ?com.UiaRect {
        const self = fromCtx(ctx);
        if (self.offscreen) return null;
        const ordinal: f64 = @floatFromInt(@intFromEnum(kind));
        return .{ .left = 100 + ordinal * 46, .top = 8, .width = 46, .height = 40 };
    }
    fn invokeFn(ctx: *anyopaque, kind: CaptionButtonKind) bool {
        const self = fromCtx(ctx);
        self.invoked = kind;
        self.invoke_count += 1;
        return self.invoke_ok;
    }
    fn state(self: *TestCaption) CaptionButtonsState {
        return .{
            .ctx = @ptrCast(self),
            .painted = paintedFn,
            .bounds = boundsFn,
            .zoomed = zoomedFn,
            .invoke = invokeFn,
        };
    }
};

fn testRoot(caption: *TestCaption) !*RootProvider {
    const provider = try RootProvider.create(std.testing.allocator, @ptrFromInt(0x1));
    provider.setCaptionButtons(caption.state());
    return provider;
}

fn testCaptionChild(
    provider: *RootProvider,
    direction: i32,
) !*CaptionButtonProvider {
    var out: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(
        com.S_OK,
        RootProvider.Navigate(&provider.fragment, direction, &out),
    );
    return CaptionButtonProvider.fromFragment(out orelse return error.NoChild);
}

test "caption button names follow kind and zoomed state" {
    try std.testing.expectEqualStrings("Minimize", captionButtonName(.minimize, false));
    try std.testing.expectEqualStrings("Minimize", captionButtonName(.minimize, true));
    try std.testing.expectEqualStrings("Maximize", captionButtonName(.maximize, false));
    try std.testing.expectEqualStrings("Restore", captionButtonName(.maximize, true));
    try std.testing.expectEqualStrings("Close", captionButtonName(.close, false));
    try std.testing.expectEqualStrings("Close", captionButtonName(.close, true));
}

test "caption button UTF-16 names match their UTF-8 names" {
    for (caption_button_order) |kind| {
        for ([_]bool{ false, true }) |zoomed| {
            const utf8 = captionButtonName(kind, zoomed);
            const utf16 = captionButtonNameLiteral(kind, zoomed);
            var expected: [16]u16 = undefined;
            const len = try std.unicode.utf8ToUtf16Le(&expected, utf8);
            try std.testing.expectEqualSlices(u16, expected[0..len], utf16[0..len]);
            try std.testing.expectEqual(@as(u16, 0), utf16[len]);
        }
    }
}

test "root advertises fragment interfaces only once caption buttons exist" {
    var provider = try RootProvider.create(std.testing.allocator, @ptrFromInt(0x1));
    defer _ = RootProvider.Release(&provider.base);

    var out: ?*anyopaque = null;
    try std.testing.expectEqual(
        com.E_NOINTERFACE,
        RootProvider.QueryInterface(&provider.base, &com.IID_IRawElementProviderFragmentRoot, &out),
    );

    var caption = TestCaption{};
    provider.setCaptionButtons(caption.state());
    try std.testing.expectEqual(
        com.S_OK,
        RootProvider.QueryInterface(&provider.base, &com.IID_IRawElementProviderFragmentRoot, &out),
    );
    try std.testing.expect(out == @as(*anyopaque, @ptrCast(&provider.fragment_root)));
    try std.testing.expectEqual(@as(u32, 1), RootProvider.Release(&provider.base));
}

test "root exposes the three caption buttons in paint order" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);

    const first = try testCaptionChild(provider, com.NavigateDirection_FirstChild);
    try std.testing.expectEqual(CaptionButtonKind.minimize, first.kind);

    var out: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.Navigate(
        &first.fragment,
        com.NavigateDirection_NextSibling,
        &out,
    ));
    const second = CaptionButtonProvider.fromFragment(out.?);
    try std.testing.expectEqual(CaptionButtonKind.maximize, second.kind);

    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.Navigate(
        &second.fragment,
        com.NavigateDirection_NextSibling,
        &out,
    ));
    const third = CaptionButtonProvider.fromFragment(out.?);
    try std.testing.expectEqual(CaptionButtonKind.close, third.kind);

    // The rightmost button has no next sibling, and the leftmost has no
    // previous one: exactly three children, no wrap.
    out = null;
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.Navigate(
        &third.fragment,
        com.NavigateDirection_NextSibling,
        &out,
    ));
    try std.testing.expect(out == null);
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.Navigate(
        &first.fragment,
        com.NavigateDirection_PreviousSibling,
        &out,
    ));
    try std.testing.expect(out == null);

    // LastChild is the same button NextSibling walked to.
    const last = try testCaptionChild(provider, com.NavigateDirection_LastChild);
    try std.testing.expectEqual(CaptionButtonKind.close, last.kind);

    // Parent navigation returns this root's fragment, with a ref.
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.Navigate(
        &first.fragment,
        com.NavigateDirection_Parent,
        &out,
    ));
    try std.testing.expect(out == &provider.fragment);
    _ = RootProvider.FragmentRelease(out.?);

    try std.testing.expectEqual(@as(u32, 0), CaptionButtonProvider.Release(&first.base));
    try std.testing.expectEqual(@as(u32, 0), CaptionButtonProvider.Release(&second.base));
    try std.testing.expectEqual(@as(u32, 0), CaptionButtonProvider.Release(&third.base));
    try std.testing.expectEqual(@as(u32, 0), CaptionButtonProvider.Release(&last.base));
}

test "caption maximize button reports Restore while the window is zoomed" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);

    const button = try testCaptionChild(provider, com.NavigateDirection_FirstChild);
    var maximize = try CaptionButtonProvider.create(
        std.testing.allocator,
        provider,
        .maximize,
    );
    defer _ = CaptionButtonProvider.Release(&maximize.base);
    defer _ = CaptionButtonProvider.Release(&button.base);

    var name = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPropertyValue(
        &maximize.base,
        constants.UIA_NamePropertyId,
        &name,
    ));
    defer _ = com.VariantClear(&name);
    const maximize_expected = std.unicode.utf8ToUtf16LeStringLiteral("Maximize");
    try std.testing.expectEqual(@as(u32, maximize_expected.len), com.SysStringLen(name.value.bstr));
    try std.testing.expectEqualSlices(u16, maximize_expected, name.value.bstr.?[0..maximize_expected.len]);

    caption.zoomed = true;
    var zoomed_name = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPropertyValue(
        &maximize.base,
        constants.UIA_NamePropertyId,
        &zoomed_name,
    ));
    defer _ = com.VariantClear(&zoomed_name);
    const restore_expected = std.unicode.utf8ToUtf16LeStringLiteral("Restore");
    try std.testing.expectEqual(@as(u32, restore_expected.len), com.SysStringLen(zoomed_name.value.bstr));
    try std.testing.expectEqualSlices(u16, restore_expected, zoomed_name.value.bstr.?[0..restore_expected.len]);

    // The other two names do not move with the zoomed state.
    var minimize_name = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPropertyValue(
        &button.base,
        constants.UIA_NamePropertyId,
        &minimize_name,
    ));
    defer _ = com.VariantClear(&minimize_name);
    const minimize_expected = std.unicode.utf8ToUtf16LeStringLiteral("Minimize");
    try std.testing.expectEqualSlices(u16, minimize_expected, minimize_name.value.bstr.?[0..minimize_expected.len]);
}

test "caption buttons are Button controls that are not keyboard focusable" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);
    const button = try testCaptionChild(provider, com.NavigateDirection_FirstChild);
    defer _ = CaptionButtonProvider.Release(&button.base);

    var control_type = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPropertyValue(
        &button.base,
        constants.UIA_ControlTypePropertyId,
        &control_type,
    ));
    try std.testing.expectEqual(constants.UIA_ButtonControlTypeId, control_type.value.i4);

    for ([_]i32{
        constants.UIA_IsKeyboardFocusablePropertyId,
        constants.UIA_HasKeyboardFocusPropertyId,
    }) |property_id| {
        var value = com.VARIANT.empty();
        try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPropertyValue(
            &button.base,
            property_id,
            &value,
        ));
        try std.testing.expectEqual(com.VT_BOOL, value.vt);
        try std.testing.expectEqual(com.VARIANT_FALSE, value.value.bool_val);
    }

    // Not focusable means SetFocus must not pretend otherwise.
    try std.testing.expectEqual(
        com.E_NOTIMPL,
        CaptionButtonProvider.SetFocus(&button.fragment),
    );

    var pattern: ?*com.IUnknown = null;
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPatternProvider(
        &button.base,
        constants.UIA_InvokePatternId,
        &pattern,
    ));
    try std.testing.expect(pattern != null);
    _ = CaptionButtonProvider.Release(&button.base);

    // No pattern other than Invoke is claimed.
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPatternProvider(
        &button.base,
        constants.UIA_TogglePatternId,
        &pattern,
    ));
    try std.testing.expect(pattern == null);
}

test "caption button bounds follow the painted rect and report offscreen" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);
    const button = try testCaptionChild(provider, com.NavigateDirection_LastChild);
    defer _ = CaptionButtonProvider.Release(&button.base);

    var rect: com.UiaRect = undefined;
    try std.testing.expectEqual(
        com.S_OK,
        CaptionButtonProvider.GetBoundingRectangle(&button.fragment, &rect),
    );
    try std.testing.expectEqual(@as(f64, 192), rect.left);
    try std.testing.expectEqual(@as(f64, 8), rect.top);
    try std.testing.expectEqual(@as(f64, 46), rect.width);
    try std.testing.expectEqual(@as(f64, 40), rect.height);

    var offscreen = com.VARIANT.empty();
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPropertyValue(
        &button.base,
        constants.UIA_IsOffscreenPropertyId,
        &offscreen,
    ));
    try std.testing.expectEqual(com.VARIANT_FALSE, offscreen.value.bool_val);

    caption.offscreen = true;
    try std.testing.expectEqual(
        com.S_OK,
        CaptionButtonProvider.GetBoundingRectangle(&button.fragment, &rect),
    );
    try std.testing.expectEqual(@as(f64, 0), rect.width);
    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.GetPropertyValue(
        &button.base,
        constants.UIA_IsOffscreenPropertyId,
        &offscreen,
    ));
    try std.testing.expectEqual(com.VARIANT_TRUE, offscreen.value.bool_val);
}

test "caption buttons leave the tree when the integrated titlebar is off" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);
    const button = try testCaptionChild(provider, com.NavigateDirection_FirstChild);
    defer _ = CaptionButtonProvider.Release(&button.base);

    caption.painted = false;

    var out: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, RootProvider.Navigate(
        &provider.fragment,
        com.NavigateDirection_FirstChild,
        &out,
    ));
    try std.testing.expect(out == null);

    var value = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        CaptionButtonProvider.GetPropertyValue(&button.base, constants.UIA_NamePropertyId, &value),
    );
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        CaptionButtonProvider.Invoke(&button.invoke_iface),
    );
    try std.testing.expectEqual(@as(usize, 0), caption.invoke_count);
}

test "caption button Invoke reaches the owner and reports a failed post" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);
    const button = try testCaptionChild(provider, com.NavigateDirection_LastChild);
    defer _ = CaptionButtonProvider.Release(&button.base);

    try std.testing.expectEqual(com.S_OK, CaptionButtonProvider.Invoke(&button.invoke_iface));
    try std.testing.expectEqual(CaptionButtonKind.close, caption.invoked.?);
    try std.testing.expectEqual(@as(usize, 1), caption.invoke_count);

    caption.invoke_ok = false;
    try std.testing.expectEqual(
        com.UIA_E_INVALIDOPERATION,
        CaptionButtonProvider.Invoke(&button.invoke_iface),
    );
    try std.testing.expectEqual(@as(usize, 2), caption.invoke_count);
}

test "caption button runtime id is stable per kind" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);
    const first = try testCaptionChild(provider, com.NavigateDirection_FirstChild);
    defer _ = CaptionButtonProvider.Release(&first.base);
    const last = try testCaptionChild(provider, com.NavigateDirection_LastChild);
    defer _ = CaptionButtonProvider.Release(&last.base);

    var minimize_id: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        CaptionButtonProvider.GetRuntimeId(&first.fragment, &minimize_id),
    );
    defer _ = com.SafeArrayDestroy(minimize_id);
    var close_id: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        CaptionButtonProvider.GetRuntimeId(&last.fragment, &close_id),
    );
    defer _ = com.SafeArrayDestroy(close_id);

    var index: i32 = 2;
    var minimize_kind: i32 = -1;
    var close_kind: i32 = -1;
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(minimize_id.?, &index, @ptrCast(&minimize_kind)),
    );
    try std.testing.expectEqual(
        com.S_OK,
        com.SafeArrayGetElement(close_id.?, &index, @ptrCast(&close_kind)),
    );
    try std.testing.expectEqual(@intFromEnum(CaptionButtonKind.minimize), minimize_kind);
    try std.testing.expectEqual(@intFromEnum(CaptionButtonKind.close), close_kind);

    // The window's own id is appended by UIA, and the root itself defers
    // to the host provider for its runtime id.
    var root_id: ?*com.SAFEARRAY = null;
    try std.testing.expectEqual(
        com.S_OK,
        RootProvider.GetRuntimeId(&provider.fragment, &root_id),
    );
    try std.testing.expect(root_id == null);
}

test "caption fragment root hit tests only the painted buttons" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);

    var out: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(com.S_OK, RootProvider.ElementProviderFromPoint(
        &provider.fragment_root,
        170,
        20,
        &out,
    ));
    const hit = CaptionButtonProvider.fromFragment(out orelse return error.NoHit);
    try std.testing.expectEqual(CaptionButtonKind.maximize, hit.kind);
    try std.testing.expectEqual(@as(u32, 0), CaptionButtonProvider.Release(&hit.base));

    out = null;
    try std.testing.expectEqual(com.S_OK, RootProvider.ElementProviderFromPoint(
        &provider.fragment_root,
        10,
        400,
        &out,
    ));
    try std.testing.expect(out == null);

    // The root never claims focus for a caption button.
    try std.testing.expectEqual(
        com.S_OK,
        RootProvider.FragmentRootGetFocus(&provider.fragment_root, &out),
    );
    try std.testing.expect(out == null);
}

test "detached root drops its caption children" {
    var caption = TestCaption{};
    var provider = try testRoot(&caption);
    defer _ = RootProvider.Release(&provider.base);
    const button = try testCaptionChild(provider, com.NavigateDirection_FirstChild);
    defer _ = CaptionButtonProvider.Release(&button.base);

    provider.detach();

    var out: ?*com.IRawElementProviderFragment = null;
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        RootProvider.Navigate(&provider.fragment, com.NavigateDirection_FirstChild, &out),
    );
    var value = com.VARIANT.empty();
    try std.testing.expectEqual(
        com.UIA_E_ELEMENTNOTAVAILABLE,
        CaptionButtonProvider.GetPropertyValue(&button.base, constants.UIA_NamePropertyId, &value),
    );
}
