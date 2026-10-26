//! Command palette orchestration. Host and Surface retain coordination.
const win32 = @import("../win32.zig");
const runtime = win32.palette_controller_runtime;
const App = runtime.App;
const HDC = runtime.HDC;
const HGDIOBJ = runtime.HGDIOBJ;
const HWND = runtime.HWND;
const Host = runtime.Host;
const LPARAM = runtime.LPARAM;
const LRESULT = runtime.LRESULT;
const PAINTSTRUCT = runtime.PAINTSTRUCT;
const PaletteCatalog = runtime.PaletteCatalog;
const PaletteCompletion = runtime.PaletteCompletion;
const PaletteItem = runtime.PaletteItem;
const PalettePayload = runtime.PalettePayload;
const PalettePresentation = runtime.PalettePresentation;
const PaletteRanked = runtime.PaletteRanked;
const PaletteSnapshot = runtime.PaletteSnapshot;
const PaletteStableId = runtime.PaletteStableId;
const RECT = runtime.RECT;
const UINT = runtime.UINT;
const WNDCLASSEXW = runtime.WNDCLASSEXW;
const WPARAM = runtime.WPARAM;
const appendOwnedString = runtime.appendOwnedString;
const c = runtime.c;
const drawRectBorder = runtime.drawRectBorder;
const fillSolidRect = runtime.fillSolidRect;
const host_overlay_height = runtime.host_overlay_height;
const lParamBits = runtime.lParamBits;
const lastError = runtime.lastError;
const log = runtime.log;
const overlayEditText = runtime.overlayEditText;
const ownedStringEquals = runtime.ownedStringEquals;
const paint_text = runtime.paint_text;
const paletteCompletionText = runtime.paletteCompletionText;
const palette_action_capacity = runtime.palette_action_capacity;
const palette_catalog_label_bytes = runtime.palette_catalog_label_bytes;
const palette_list_class_name = runtime.palette_list_class_name;
const palette_max_visible_rows = runtime.palette_max_visible_rows;
const palette_row_height = runtime.palette_row_height;
const profileIndexByKey = runtime.profileIndexByKey;
const runUiActionOrLog = runtime.runUiActionOrLog;
const signedHighWord = runtime.signedHighWord;
const std = runtime.std;
const sys = runtime.sys;
const themepkg = runtime.themepkg;
const utf8PrefixLen = runtime.utf8PrefixLen;
const wheelDeltaFromWParam = runtime.wheelDeltaFromWParam;
const win32_input = runtime.win32_input;
const win32_layouts = runtime.win32_layouts;
const win32_palette = runtime.win32_palette;
const win32_settings = runtime.win32_settings;
const win32_uia = runtime.win32_uia;
const windowData = runtime.windowData;
const test_runtime = if (@import("builtin").is_test) win32.palette_controller_test_runtime else struct {};
const BannerTestWindow = test_runtime.BannerTestWindow;
const CoreApp = test_runtime.CoreApp;
const TestSession = test_runtime.TestSession;
const builtin = test_runtime.builtin;
const runOnPrivateDesktop = test_runtime.runOnPrivateDesktop;

const PaletteListTransition = struct {
    relayout: bool,
    exposes_content: bool,
    announce_no_matches: bool,
};

const PaletteNoMatchNotificationTarget = enum { list, edit };

const PaletteViewport = struct {
    selected: usize,
    scroll: usize,
};

const PaletteRowColumns = struct {
    title: RECT,
    subtitle: RECT,
    shortcut: RECT,
};

pub fn paletteVisibleRowCapacity(available_height: i32, row_height: i32) usize {
    if (row_height <= 0 or available_height < row_height) return 0;
    const raw: usize = @intCast(@divTrunc(available_height, row_height));
    return @min(raw, palette_max_visible_rows);
}

fn paletteListTransition(
    previous_count: usize,
    next_count: usize,
    row_capacity: usize,
) PaletteListTransition {
    const previous_rows = @min(previous_count, row_capacity);
    const next_rows = @min(next_count, row_capacity);
    return .{
        .relayout = previous_rows != next_rows,
        .exposes_content = next_rows < previous_rows,
        .announce_no_matches = previous_count > 0 and next_count == 0,
    };
}

fn paletteNoMatchNotificationTarget(
    list_available: bool,
    list_visible: bool,
    edit_available: bool,
) ?PaletteNoMatchNotificationTarget {
    if (list_available and list_visible) return .list;
    if (edit_available) return .edit;
    if (list_available) return .list;
    return null;
}

pub fn paletteListRect(
    client_width: i32,
    desired_left: i32,
    right_padding: i32,
    top: i32,
    height: i32,
) RECT {
    const client_right = @max(0, client_width);
    const right = @max(0, client_right - @max(0, right_padding));
    const left = @min(@max(0, desired_left), right);
    return .{
        .left = left,
        .top = top,
        .right = right,
        .bottom = top + @max(0, height),
    };
}

pub fn paletteListWidthIsReadable(rect: RECT, minimum_width: i32) bool {
    return rect.right - rect.left >= @max(1, minimum_width);
}

fn paletteRowTitleColor(
    destructive: bool,
    selected: bool,
    normal_color: u32,
    selected_color: u32,
    destructive_color: u32,
) u32 {
    if (destructive) return destructive_color;
    if (selected) return selected_color;
    return normal_color;
}

fn paletteRowColumns(
    row: RECT,
    padding: i32,
    preferred_title_width: i32,
    minimum_subtitle_width: i32,
    preferred_shortcut_width: i32,
) PaletteRowColumns {
    const left = @min(@max(row.left, row.left + @max(0, padding)), row.right);
    const right = @max(left, row.right - @max(0, padding));
    const available = right - left;
    const title_width = @min(available, @max(0, preferred_title_width));
    const subtitle_reservation = @min(
        available - title_width,
        @max(0, minimum_subtitle_width),
    );
    const shortcut_room = available - title_width - subtitle_reservation;
    const preferred_shortcut = @max(0, preferred_shortcut_width);
    const minimum_legible_shortcut = @min(preferred_shortcut, @max(1, minimum_subtitle_width));
    const shortcut_width = if (shortcut_room >= minimum_legible_shortcut)
        @min(shortcut_room, preferred_shortcut)
    else
        0;
    const title_right = left + title_width;
    const shortcut_left = right - shortcut_width;
    return .{
        .title = .{
            .left = left,
            .top = row.top,
            .right = title_right,
            .bottom = row.bottom,
        },
        .subtitle = .{
            .left = title_right,
            .top = row.top,
            .right = shortcut_left,
            .bottom = row.bottom,
        },
        .shortcut = .{
            .left = shortcut_left,
            .top = row.top,
            .right = right,
            .bottom = row.bottom,
        },
    };
}

pub fn clampPaletteViewport(
    result_count: usize,
    visible_rows: usize,
    selected: usize,
    scroll: usize,
) PaletteViewport {
    if (result_count == 0) return .{ .selected = 0, .scroll = 0 };
    if (visible_rows == 0) return .{
        .selected = @min(selected, result_count - 1),
        .scroll = 0,
    };
    const clamped_selected = @min(selected, result_count - 1);
    const max_scroll = result_count - @min(result_count, visible_rows);
    var clamped_scroll = @min(scroll, max_scroll);
    if (clamped_selected < clamped_scroll) {
        clamped_scroll = clamped_selected;
    } else if (clamped_selected >= clamped_scroll + visible_rows) {
        clamped_scroll = clamped_selected - visible_rows + 1;
    }
    return .{ .selected = clamped_selected, .scroll = clamped_scroll };
}

/// Draw a single-line, left-aligned, vertically-centred, ellipsized
/// string into the rect. Used by the palette list row painter.
fn drawPaletteRowText(hdc: HDC, text: []const u8, rect: RECT, color: u32) void {
    if (text.len == 0) return;
    // Configured titles and descriptions can be arbitrarily long. Bound
    // the conversion before writing and avoid allocation on every paint.
    var buf: [256]u16 = undefined;
    const n = paint_text.utf8ToUtf16LeBounded(&buf, text);

    _ = sys.SetTextColor(hdc, color);
    var r = rect;
    _ = sys.DrawTextW(
        hdc,
        @ptrCast(&buf),
        @intCast(n),
        &r,
        c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );
}

fn getPaletteListHost(hwnd: HWND) ?*Host {
    return windowData(Host, hwnd);
}

/// Trampoline bridging `PaletteListState.name` (C-compatible fn
/// pointer shape) into `Host.buildPaletteListName`. `ctx` is the
/// const-erased `*Host` stashed on `PaletteListState`; the provider
/// never mutates `self` so casting away const here is safe.
fn paletteListNameThunk(ctx: *anyopaque, buf: []u8) []const u8 {
    const host: *const Host = @ptrCast(@alignCast(ctx));
    return host.buildPaletteListName(buf);
}

fn paletteListRowCountThunk(ctx: *anyopaque) usize {
    const host: *const Host = @ptrCast(@alignCast(ctx));
    return host.palette_list_ranked_count;
}

fn paletteListSelectedIndexThunk(ctx: *anyopaque) ?usize {
    const host: *const Host = @ptrCast(@alignCast(ctx));
    if (host.palette_list_ranked_count == 0) return null;
    return @min(host.palette_list_selected, host.palette_list_ranked_count - 1);
}

fn paletteListRowNameThunk(ctx: *anyopaque, index: usize, buf: []u8) []const u8 {
    const host: *const Host = @ptrCast(@alignCast(ctx));
    return host.buildPaletteRowName(index, buf);
}

fn paletteListRowEnabledThunk(ctx: *anyopaque, index: usize) bool {
    const host: *const Host = @ptrCast(@alignCast(ctx));
    if (index >= host.palette_list_ranked_count) return false;
    const catalog = if (host.palette_catalog) |*value| value else return true;
    const descriptor = catalog.descriptorFor(host.palette_list_ranked[index]) orelse return false;
    return descriptor.item.enabled;
}

fn paletteListRowIdThunk(ctx: *anyopaque, index: usize) u64 {
    const host: *const Host = @ptrCast(@alignCast(ctx));
    if (index >= host.palette_list_ranked_count) return 0;
    return host.palette_list_ranked[index].id.value;
}

fn paletteListSelectRowThunk(ctx: *anyopaque, index: usize) void {
    const host: *Host = @ptrCast(@alignCast(ctx));
    _ = host.setPaletteListSelection(index);
}

fn paletteListGeometryThunk(ctx: *anyopaque) ?win32_uia.PaletteListGeometry {
    const host: *const Host = @ptrCast(@alignCast(ctx));
    const hwnd = host.palette_list_hwnd orelse return null;
    var rect: RECT = undefined;
    if (sys.GetWindowRect(hwnd, &rect) == 0) return null;
    const row_height = host.scaled(palette_row_height);
    if (row_height <= 0 or rect.right <= rect.left or rect.bottom <= rect.top) return null;
    const remaining = host.palette_list_ranked_count -| host.palette_list_scroll;
    return .{
        .bounds = .{
            .left = @floatFromInt(rect.left),
            .top = @floatFromInt(rect.top),
            .width = @floatFromInt(rect.right - rect.left),
            .height = @floatFromInt(rect.bottom - rect.top),
        },
        .first_visible = host.palette_list_scroll,
        .visible_count = @min(remaining, host.palette_list_visible_rows),
        .row_height = @floatFromInt(row_height),
    };
}

fn paletteListProc(
    hwnd: HWND,
    msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) LRESULT {
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            if (getPaletteListHost(hwnd)) |host| host.paintPaletteList();
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            const host = getPaletteListHost(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
            const y: i32 = signedHighWord(lParamBits(lParam));
            const row = host.paletteRowAtY(y);
            if (row) |r| host.invokePaletteRow(r) catch |err| {
                std.log.warn("palette row invoke failed err={}", .{err});
            };
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            const host = getPaletteListHost(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
            host.scrollPaletteList(wheelDeltaFromWParam(wParam));
            return 0;
        },
        c.WM_GETOBJECT => {
            const host = getPaletteListHost(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
            if (!host.app.com_initialized) return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
            if (host.palette_list_uia_provider) |provider| {
                if (win32_uia.returnPaletteListProvider(
                    hwnd,
                    wParam,
                    lParam,
                    provider,
                )) |lr| return lr;
                return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
            }
            const state = host.paletteListUiaState();
            if (win32_uia.handlePaletteListGetObject(
                std.heap.page_allocator,
                hwnd,
                wParam,
                lParam,
                state,
            )) |lr| return lr;
            return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        else => return sys.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

pub fn paletteDisconnectThunk(ctx: *anyopaque) win32_uia.HRESULT {
    return (@as(*win32_uia.PaletteListProvider, @ptrCast(@alignCast(ctx)))).disconnect();
}

pub fn paletteReleaseThunk(ctx: *anyopaque) void {
    const provider: *win32_uia.PaletteListProvider = @ptrCast(@alignCast(ctx));
    _ = win32_uia.PaletteListProvider.Release(&provider.base);
}

test "win32 palette UIA state exposes rows and can select a row" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var host: Host = undefined;
    host.overlay_mode = .command_palette;
    host.palette_list_ranked_count = 4;
    host.palette_list_visible_rows = 4;
    host.palette_list_selected = 1;
    host.palette_list_scroll = 0;
    host.palette_list_hwnd = null;
    host.overlay_edit_hwnd = null;
    host.palette_list_uia_provider = null;
    host.palette_catalog = null;
    host.palette_theme_preview_original = null;

    const state = host.paletteListUiaStateWithThreading(true);
    try std.testing.expect(state.use_com_threading);
    try std.testing.expectEqual(@as(usize, 4), state.row_count.?(state.ctx));
    try std.testing.expectEqual(@as(?usize, 1), state.selected_index.?(state.ctx));

    var name_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Command palette results", state.name(state.ctx, &name_buf));

    var row_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Command palette row", state.row_name.?(state.ctx, 2, &row_buf));
    try std.testing.expect(state.row_enabled.?(state.ctx, 2));
    try std.testing.expect(!state.row_enabled.?(state.ctx, 9));

    state.select_row.?(state.ctx, 3);
    try std.testing.expectEqual(@as(usize, 3), host.palette_list_selected);
    try std.testing.expectEqual(@as(?usize, 3), state.selected_index.?(state.ctx));

    state.select_row.?(state.ctx, 9);
    try std.testing.expectEqual(@as(usize, 3), host.palette_list_selected);
}

test "win32 palette list geometry clamps rows and detects exposed content" {
    try std.testing.expectEqual(@as(usize, 7), paletteVisibleRowCapacity(2000, 36));
    try std.testing.expectEqual(@as(usize, 3), paletteVisibleRowCapacity(110, 36));
    try std.testing.expectEqual(@as(usize, 0), paletteVisibleRowCapacity(10, 36));

    try std.testing.expectEqual(
        PaletteListTransition{
            .relayout = true,
            .exposes_content = false,
            .announce_no_matches = false,
        },
        paletteListTransition(0, 1, 7),
    );
    try std.testing.expectEqual(
        PaletteListTransition{
            .relayout = true,
            .exposes_content = true,
            .announce_no_matches = false,
        },
        paletteListTransition(7, 1, 7),
    );
    try std.testing.expectEqual(
        PaletteListTransition{
            .relayout = true,
            .exposes_content = true,
            .announce_no_matches = true,
        },
        paletteListTransition(1, 0, 7),
    );
    try std.testing.expectEqual(
        PaletteListTransition{
            .relayout = false,
            .exposes_content = false,
            .announce_no_matches = false,
        },
        paletteListTransition(20, 10, 7),
    );
    try std.testing.expect(
        paletteListTransition(1, 0, 0).announce_no_matches,
    );
    try std.testing.expectEqual(
        PaletteNoMatchNotificationTarget.list,
        paletteNoMatchNotificationTarget(true, true, true).?,
    );
    try std.testing.expectEqual(
        PaletteNoMatchNotificationTarget.edit,
        paletteNoMatchNotificationTarget(true, false, true).?,
    );
    try std.testing.expectEqual(
        PaletteNoMatchNotificationTarget.list,
        paletteNoMatchNotificationTarget(true, false, false).?,
    );
    try std.testing.expectEqual(
        @as(?PaletteNoMatchNotificationTarget, null),
        paletteNoMatchNotificationTarget(false, false, false),
    );

    try std.testing.expectEqual(
        PaletteViewport{ .selected = 6, .scroll = 6 },
        clampPaletteViewport(10, 1, 6, 0),
    );
    try std.testing.expectEqual(
        PaletteViewport{ .selected = 9, .scroll = 3 },
        clampPaletteViewport(10, 7, 99, 99),
    );
    try std.testing.expectEqual(
        PaletteViewport{ .selected = 6, .scroll = 0 },
        clampPaletteViewport(10, 0, 6, 4),
    );
    try std.testing.expectEqual(
        PaletteViewport{ .selected = 6, .scroll = 0 },
        clampPaletteViewport(10, 7, clampPaletteViewport(10, 0, 6, 4).selected, 0),
    );
}

test "win32 palette list and columns stay inside narrow client bounds" {
    const list = paletteListRect(160, 220, 12, 58, 36);
    try std.testing.expectEqual(RECT{
        .left = 148,
        .top = 58,
        .right = 148,
        .bottom = 94,
    }, list);

    const wide = paletteRowColumns(
        .{ .left = 0, .top = 0, .right = 560, .bottom = 36 },
        12,
        200,
        80,
        140,
    );
    try std.testing.expectEqual(@as(i32, 12), wide.title.left);
    try std.testing.expectEqual(@as(i32, 212), wide.title.right);
    try std.testing.expectEqual(@as(i32, 408), wide.shortcut.left);
    try std.testing.expectEqual(@as(i32, 548), wide.shortcut.right);

    // Shortcut collapses first while title and the minimum subtitle lane
    // remain intact.
    const narrowing = paletteRowColumns(
        .{ .left = 0, .top = 0, .right = 324, .bottom = 36 },
        12,
        200,
        80,
        140,
    );
    try std.testing.expectEqual(@as(i32, 212), narrowing.title.right);
    try std.testing.expectEqual(@as(i32, 312), narrowing.subtitle.right);
    try std.testing.expectEqual(@as(i32, 312), narrowing.shortcut.left);
    try std.testing.expectEqual(@as(i32, 312), narrowing.shortcut.right);

    // Once the shortcut is gone, subtitle then title consume only the
    // remaining nonnegative space.
    const narrow = paletteRowColumns(
        .{ .left = 0, .top = 0, .right = 180, .bottom = 36 },
        12,
        200,
        80,
        140,
    );
    try std.testing.expectEqual(@as(i32, 168), narrow.title.right);
    try std.testing.expectEqual(narrow.title.right, narrow.subtitle.left);
    try std.testing.expectEqual(narrow.subtitle.left, narrow.subtitle.right);
    try std.testing.expectEqual(narrow.subtitle.right, narrow.shortcut.left);
    try std.testing.expectEqual(narrow.shortcut.left, narrow.shortcut.right);
    try std.testing.expect(narrow.title.left <= narrow.title.right);
    try std.testing.expect(narrow.title.right <= narrow.subtitle.left);
    try std.testing.expect(narrow.subtitle.right <= narrow.shortcut.left);
    try std.testing.expect(narrow.shortcut.right <= 180);

    for ([_]u32{ 96, 192, 288 }) |dpi| {
        for ([_]i32{ 120, 240, 364, 600 }) |logical_width| {
            const physical_width = Host.scaledBy(logical_width, dpi);
            const scaled_padding = Host.scaledBy(12, dpi);
            const columns = paletteRowColumns(
                .{ .left = 0, .top = 0, .right = physical_width, .bottom = Host.scaledBy(36, dpi) },
                scaled_padding,
                Host.scaledBy(200, dpi),
                Host.scaledBy(80, dpi),
                Host.scaledBy(140, dpi),
            );
            try std.testing.expect(columns.title.left >= 0);
            try std.testing.expect(columns.title.left <= columns.title.right);
            try std.testing.expect(columns.title.right <= columns.subtitle.left);
            try std.testing.expect(columns.subtitle.left <= columns.subtitle.right);
            try std.testing.expect(columns.subtitle.right <= columns.shortcut.left);
            try std.testing.expect(columns.shortcut.left <= columns.shortcut.right);
            try std.testing.expect(columns.shortcut.right <= physical_width);
        }
    }

    try std.testing.expect(!paletteListWidthIsReadable(list, 160));
    try std.testing.expect(paletteListWidthIsReadable(
        .{ .left = 20, .top = 0, .right = 180, .bottom = 36 },
        160,
    ));
    try std.testing.expectEqual(@as(u32, 0x33), paletteRowTitleColor(true, true, 0x11, 0x22, 0x33));
    try std.testing.expectEqual(@as(u32, 0x33), paletteRowTitleColor(true, false, 0x11, 0x22, 0x33));
}

test "win32 rich palette completion cycles duplicate display text by stable id" {
    var items: [2]PaletteItem = undefined;
    var payloads: [2]PalettePayload = undefined;
    var catalog = try PaletteCatalog.init(&items, &payloads);
    try catalog.append(.{
        .item = .{
            .id = win32_palette.catalog.stableStringId(.tab, "tab-one"),
            .title = "Same title",
            .keywords = "same",
        },
        .payload = .{ .tab = 1 },
    });
    try catalog.append(.{
        .item = .{
            .id = win32_palette.catalog.stableStringId(.tab, "tab-two"),
            .title = "Same title",
            .keywords = "same",
        },
        .payload = .{ .tab = 2 },
    });

    var host: Host = undefined;
    host.palette_catalog = catalog;
    const first = host.richPaletteCompletionCandidate("same", "same", null, false).?;
    const second = host.richPaletteCompletionCandidate("same", first.text, first.id, false).?;
    try std.testing.expectEqualStrings("Same title", first.text);
    try std.testing.expectEqualStrings("Same title", second.text);
    try std.testing.expect(!first.id.eql(second.id));
}

pub const AppControls = struct {
    /// Resolve `%LOCALAPPDATA%\noctty\palette-mru.txt`. Caller frees
    /// with `core_app.alloc`.
    pub fn paletteMruPath(self: *const App) ?[]u8 {
        return self.localAppDataPath("palette-mru.txt");
    }

    /// Populate `palette_mru` from the on-disk file, one action per line
    /// (newest first). Missing file, I/O errors, and parse failures all
    /// degrade to "start empty" — the MRU is a UX nicety, not a
    /// correctness invariant.
    pub fn loadPaletteMru(self: *App) void {
        const path = self.paletteMruPath() orelse return;
        defer self.core_app.alloc.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        // Cap read size at 64 KB — way more than the 5 × ~200-char
        // actions we expect, but bounded so a corrupted file can't OOM.
        const raw = file.readToEndAlloc(self.core_app.alloc, 64 * 1024) catch return;
        defer self.core_app.alloc.free(raw);

        var it = std.mem.tokenizeAny(u8, raw, "\r\n");
        var slot: usize = 0;
        while (it.next()) |line| {
            if (slot >= self.palette_mru.len) break;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;
            const duped = self.core_app.alloc.dupeZ(u8, trimmed) catch continue;
            self.palette_mru[slot] = duped;
            slot += 1;
        }
    }

    /// Write `palette_mru` to the on-disk file (newest first). Failure
    /// is silently logged — losing recent history is fine, blocking
    /// termination on file-system problems is not.
    pub fn savePaletteMru(self: *const App) void {
        // Fast path: nothing to persist.
        if (self.palette_mru[0] == null) return;

        const path = self.paletteMruPath() orelse return;
        defer self.core_app.alloc.free(path);

        if (std.fs.path.dirname(path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    std.log.warn("palette MRU: mkdir failed path={s} err={}", .{ dir, err });
                    return;
                },
            };
        }

        const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
            std.log.warn("palette MRU: create failed path={s} err={}", .{ path, err });
            return;
        };
        defer file.close();

        var fbuf: [1024]u8 = undefined;
        var fw = file.writer(&fbuf);
        for (self.palette_mru) |slot| {
            if (slot) |owned| {
                fw.interface.print("{s}\n", .{owned}) catch return;
            }
        }
        fw.interface.flush() catch {};
    }

    /// Push an action string onto the palette MRU list, dedup'd by
    /// exact match, rotating the oldest slot out. `action` is not owned
    /// by the caller; this dups it into the app allocator. Safe to call
    /// with an action that may be the same as an existing MRU entry —
    /// that entry is moved to the front without reallocating.
    pub fn pushPaletteMru(self: *App, action: []const u8) !void {
        // If action already exists, move it to slot 0.
        var existing_index: ?usize = null;
        for (self.palette_mru, 0..) |slot, i| {
            if (slot) |owned| {
                if (std.mem.eql(u8, owned, action)) {
                    existing_index = i;
                    break;
                }
            }
        }
        if (existing_index) |i| {
            if (i == 0) return;
            const top = self.palette_mru[i];
            var j: usize = i;
            while (j > 0) : (j -= 1) self.palette_mru[j] = self.palette_mru[j - 1];
            self.palette_mru[0] = top;
            return;
        }
        // Insert as new head. Free whatever falls off the end.
        const duped = try self.core_app.alloc.dupeZ(u8, action);
        errdefer self.core_app.alloc.free(duped);
        if (self.palette_mru[self.palette_mru.len - 1]) |oldest| {
            self.core_app.alloc.free(oldest);
        }
        var j: usize = self.palette_mru.len - 1;
        while (j > 0) : (j -= 1) self.palette_mru[j] = self.palette_mru[j - 1];
        self.palette_mru[0] = duped;
    }

    /// View of the MRU list as a slice of non-null entries, newest first.
    /// Shared storage; caller must not free or retain past the next
    /// `pushPaletteMru` call.
    pub fn paletteMruSlice(self: *const App, buf: *[5][]const u8) []const []const u8 {
        var n: usize = 0;
        for (self.palette_mru) |slot| {
            if (slot) |owned| {
                buf[n] = owned;
                n += 1;
            }
        }
        return buf[0..n];
    }

    pub fn ensurePaletteListClass(self: *App) !void {
        if (self.palette_list_class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &paletteListProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = sys.LoadCursorW(null, c.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = palette_list_class_name,
            .hIconSm = null,
        };

        self.palette_list_class_atom = sys.RegisterClassExW(&wc);
        if (self.palette_list_class_atom == 0) {
            return lastError();
        }
    }
};

pub const HostControls = struct {
    /// Non-owning view over the palette command lists. Lifetime is tied
    /// to `app.config` — do not hold across a reload.
    pub fn paletteSnapshot(self: *const Host) PaletteSnapshot {
        return .{
            .commands = self.app.config.@"command-palette-entry".value.items,
            .cvals = self.app.config.@"command-palette-entry".value_c.items,
        };
    }

    /// Rebuild the ranked match cache for the current EDIT query and
    /// invalidate the list so WM_PAINT redraws. Called from
    /// `syncCommandPaletteBanner` on every keystroke, and from
    /// `showOverlay(.command_palette)` when the palette opens.
    pub fn storePaletteCatalogLabel(self: *Host, value: []const u8) []const u8 {
        if (self.palette_catalog_label_count >= self.palette_catalog_labels.len) return "Terminal";
        const slot = &self.palette_catalog_labels[self.palette_catalog_label_count];
        self.palette_catalog_label_count += 1;
        const len = utf8PrefixLen(value, slot.len);
        @memcpy(slot[0..len], value[0..len]);
        return slot[0..len];
    }

    pub fn appendPaletteDescriptor(self: *Host, descriptor: win32_palette.catalog.Descriptor) bool {
        const catalog = if (self.palette_catalog) |*value| value else return false;
        catalog.append(descriptor) catch |err| {
            log.warn("palette catalog item skipped kind={} err={}", .{ descriptor.item.id.kind, err });
            return false;
        };
        return true;
    }

    pub fn releaseRetainedPaletteCatalogConfig(self: *Host) void {
        if (self.palette_catalog_retained_config) |*value| value.deinit();
        self.palette_catalog_retained_config = null;
    }

    pub fn resetPaletteCatalogConfigOwner(self: *Host) void {
        // Call only after Catalog.reset() or after hiding the List: its
        // borrowed slices must no longer be observable before this release.
        self.releaseRetainedPaletteCatalogConfig();
        self.palette_catalog_config_source = .live;
    }

    pub fn paletteListRowCapacity(self: *Host) usize {
        const hwnd = self.hwnd orelse return 0;
        var rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &rect) == 0) return 0;
        const bands = self.contentBands(
            self.tabBarHeight(),
            self.scaled(host_overlay_height),
            0,
        );
        const list_top = bands.inspector_top;
        return paletteVisibleRowCapacity(
            rect.bottom - list_top - self.scaled(8),
            self.scaled(palette_row_height),
        );
    }

    pub fn palettePresentation(self: *const Host) PalettePresentation {
        if (self.palette_list_ranked_count == 0) return .{};
        const row = @min(self.palette_list_selected, self.palette_list_ranked_count - 1);
        const catalog = if (self.palette_catalog) |*value| value else return .{
            .match_count = self.palette_list_ranked_count,
            .available = self.palette_list_visible_rows > 0,
        };
        const descriptor = catalog.descriptorFor(self.palette_list_ranked[row]) orelse return .{
            .match_count = self.palette_list_ranked_count,
            .available = self.palette_list_visible_rows > 0,
        };
        return .{
            .match_count = self.palette_list_ranked_count,
            .title = descriptor.item.title,
            .subtitle = if (descriptor.item.enabled)
                descriptor.item.subtitle
            else
                descriptor.item.disabled_reason orelse "Unavailable",
            .available = self.palette_list_visible_rows > 0,
        };
    }

    pub fn refreshPalettePresentation(self: *Host) void {
        if (self.overlay_mode != .command_palette or self.overlay_edit_hwnd == null) return;
        _ = self.syncOverlayLabel() catch false;
        _ = self.syncOverlayHint() catch false;
        _ = self.syncOverlayButtons() catch false;
        self.invalidateOverlayText();
    }

    pub fn rebuildPaletteList(self: *Host) void {
        const previous_result_count = self.palette_list_ranked_count;
        // `overlayEditText` returns either a literal "" or a borrowed
        // view of `self.cached_overlay_edit`; the Host owns the cache
        // and frees it in deinit. Do NOT free here — that either
        // undermines the literal (UB) or dangles the cache pointer,
        // so the next read returns freed memory.
        const text_raw = overlayEditText(self) catch "";
        const text = std.mem.trim(u8, text_raw, " \t\r\n");

        const snap = self.paletteSnapshot();
        // Bound the ranked-query inputs so debug logs can distinguish
        // malformed snapshots from ranker failures.
        log.debug(
            "palette rebuild begin text_len={d} cmds={d} cvals={d}",
            .{ text.len, snap.commands.len, snap.cvals.len },
        );

        const catalog = if (self.palette_catalog) |*value| value else return;
        catalog.reset();
        self.resetPaletteCatalogConfigOwner();
        self.clearPaletteInstalledThemes();
        self.clearPaletteLayoutNames();
        self.palette_catalog_label_count = 0;
        const action_batch = if (snap.commands.len > palette_action_capacity)
            error.StorageTooSmall
        else
            catalog.appendActionSnapshot(snap);
        action_batch catch |err| fallback: {
            log.warn("palette action batch rejected err={} using per-entry fallback", .{err});
            catalog.reset();
            const fallback_count = @min(
                @min(snap.commands.len, snap.cvals.len),
                palette_action_capacity,
            );
            for (0..fallback_count) |index| {
                const command_entry = snap.commands[index];
                const cval = snap.cvals[index];
                const action_text = std.mem.span(cval.action);
                var id = win32_palette.catalog.actionStableId(command_entry.title, action_text);
                id.value ^= @as(u64, @intCast(index + 1)) *% 0x9e37_79b9_7f4a_7c15;
                if (!self.appendPaletteDescriptor(.{
                    .item = .{
                        .id = id,
                        .title = command_entry.title,
                        .subtitle = command_entry.description,
                        .keywords = action_text,
                    },
                    .payload = .{ .action = .{
                        .snapshot_index = index,
                        .action = action_text,
                    } },
                })) break :fallback;
            }
        };

        for (self.tabs.items, 0..) |*tab, tab_index| {
            var title_buf: [palette_catalog_label_bytes]u8 = undefined;
            const raw_title = tab.cached_button_title orelse std.fmt.bufPrint(
                &title_buf,
                "Tab {d}",
                .{tab_index + 1},
            ) catch "Tab";
            const title = self.storePaletteCatalogLabel(raw_title);
            _ = self.appendPaletteDescriptor(.{
                .item = .{
                    .id = .{ .kind = .tab, .value = tab.id },
                    .title = title,
                    .subtitle = "Tab",
                    .keywords = "tab terminal",
                    .recency = .{ .mru_rank = if (tab_index == self.active_tab) 0 else null },
                },
                .payload = .{ .tab = tab.id },
            });

            if (tab_index != self.active_tab) {
                const target_surface = self.activeSurface();
                if (target_surface) |target| {
                    const directions = [_]struct {
                        direction: win32_palette.catalog.TransferDirection,
                        title: []const u8,
                        keywords: []const u8,
                    }{
                        .{ .direction = .left, .title = "Move tab to pane — left", .keywords = "move tab split pane left" },
                        .{ .direction = .right, .title = "Move tab to pane — right", .keywords = "move tab split pane right" },
                        .{ .direction = .up, .title = "Move tab to pane — above", .keywords = "move tab split pane up above" },
                        .{ .direction = .down, .title = "Move tab to pane — below", .keywords = "move tab split pane down below" },
                    };
                    for (directions) |move| {
                        _ = self.appendPaletteDescriptor(.{
                            .item = .{
                                .id = .{
                                    .kind = .action,
                                    .value = std.hash.Wyhash.hash(tab.id, @tagName(move.direction)),
                                },
                                .title = move.title,
                                .subtitle = title,
                                .keywords = move.keywords,
                            },
                            .payload = .{ .action = .{ .tab_transfer = .{
                                .source_tab = tab.id,
                                .target_pane = target.core().id,
                                .direction = move.direction,
                            } } },
                        });
                    }
                }
            }

            var pane_index: usize = 0;
            var iterator = tab.tree.iterator();
            while (iterator.next()) |entry| : (pane_index += 1) {
                var pane_buf: [palette_catalog_label_bytes]u8 = undefined;
                const raw_pane_title = entry.view.effectiveTitle() orelse std.fmt.bufPrint(
                    &pane_buf,
                    "Pane {d}",
                    .{pane_index + 1},
                ) catch "Pane";
                const pane_title = self.storePaletteCatalogLabel(raw_pane_title);
                _ = self.appendPaletteDescriptor(.{
                    .item = .{
                        .id = .{ .kind = .pane, .value = entry.view.core().id },
                        .title = pane_title,
                        .subtitle = title,
                        .keywords = "pane split terminal",
                        .recency = .{ .mru_rank = if (entry.view == self.activeSurface()) 0 else null },
                    },
                    .payload = .{ .pane = entry.view.core().id },
                });
            }
        }

        const profiles_ready = self.profilesForChrome();
        if (profiles_ready) {
            for (self.shownProfiles().?) |profile| {
                _ = self.appendPaletteDescriptor(.{
                    .item = .{
                        .id = win32_palette.catalog.stableStringId(.profile, profile.key),
                        .title = profile.palette_title orelse profile.label,
                        .subtitle = if (profile.kind == .ssh) "SSH host" else "Profile",
                        .keywords = profile.key,
                    },
                    .payload = .{ .profile = profile.key },
                });
            }
        }

        for (std.enums.values(win32_settings.SettingField)) |field| {
            _ = self.appendPaletteDescriptor(win32_settings.paletteDescriptor(field));
        }

        self.appendInstalledThemesToPalette(catalog);
        // Layouts come last of the dynamic providers so a large layouts
        // directory can never displace installed-theme rows near capacity.
        self.appendSavedLayoutsToPalette(catalog);

        catalog.appendReviewedHelp() catch |err| {
            log.warn("palette help batch rejected err={}", .{err});
        };
        var mru_buf: [5][]const u8 = undefined;
        const mru = self.app.paletteMruSlice(&mru_buf);
        catalog.appendRecentActionMru(snap, mru) catch |err| {
            log.warn("palette recent-action batch rejected err={}", .{err});
        };

        const ranked = catalog.rank(
            text,
            .{ .max_results = self.palette_list_ranked.len },
            &self.palette_list_ranked,
        );
        // Defensive cap: `rankedForQuery` is bounded by
        // `win32_palette.max_ranked` (256) by contract, but if anything
        // ever regresses that, a runaway `palette_list_ranked_count`
        // turns every paint/scroll/invoke into an OOB on the fixed
        // stack array. Clamp here instead of relying on the library
        // invariant alone.
        self.palette_list_ranked_count = @min(ranked.len, self.palette_list_ranked.len);
        self.palette_list_scroll = 0;
        self.palette_wheel_steps = .{};
        self.palette_list_selected = 0;

        const transition = paletteListTransition(
            previous_result_count,
            self.palette_list_ranked_count,
            self.paletteListRowCapacity(),
        );
        // Raise the structure event before relayout can hide the List HWND.
        // Route the notification through the List only while it is visible;
        // otherwise use the still-focused query Edit as the live sender.
        var structure_announced_before_layout = false;
        if (transition.announce_no_matches) {
            if (self.palette_list_uia_provider) |provider| {
                win32_uia.events.raiseStructureChanged(&provider.base, .children_invalidated, null);
                structure_announced_before_layout = true;
            }
            const list_visible = if (self.palette_list_hwnd) |hwnd| sys.IsWindowVisible(hwnd) != 0 else false;
            if (paletteNoMatchNotificationTarget(
                self.palette_list_uia_provider != null,
                list_visible,
                self.overlay_edit_uia_provider != null,
            )) |target| switch (target) {
                .list => if (self.palette_list_uia_provider) |provider| {
                    win32_uia.events.raiseNotification(&provider.base, .other, "No matches");
                },
                .edit => if (self.overlay_edit_uia_provider) |provider| {
                    win32_uia.events.raiseNotification(&provider.base, .other, "No matches");
                },
            };
        }
        if (transition.relayout) {
            self.layout() catch |err| {
                log.warn("palette result-list relayout failed err={}", .{err});
            };
            // The list is a child HWND above a WGL sibling. Shrinking or
            // hiding it exposes terminal pixels that parent-only chrome
            // invalidation cannot restore.
            if (transition.exposes_content) {
                self.invalidateVisibleSurfaceChildPaint(true, false);
            }
        }

        log.debug(
            "palette rebuild end ranked={d}",
            .{self.palette_list_ranked_count},
        );

        if (self.palette_list_hwnd) |h| _ = sys.InvalidateRect(h, null, 0);
        if (self.palette_list_uia_provider) |provider| {
            if (!structure_announced_before_layout) {
                win32_uia.events.raiseStructureChanged(&provider.base, .children_invalidated, null);
            }
        }
        self.announcePaletteSelection();
        self.previewSelectedPaletteTheme();
    }

    pub fn setPaletteListSelection(self: *Host, next: usize) bool {
        if (self.overlay_mode != .command_palette) return false;
        if (next >= self.palette_list_ranked_count) return false;
        const visible_rows = self.palette_list_visible_rows;
        if (visible_rows == 0) return false;

        // Keyboard, pointer selection and UIA begin a new interaction; none
        // should complete a precision-wheel gesture from before it.
        self.palette_wheel_steps = .{};

        const changed = self.palette_list_selected != next;
        self.palette_list_selected = next;
        if (next < self.palette_list_scroll) {
            self.palette_list_scroll = next;
        } else if (next >= self.palette_list_scroll + visible_rows) {
            self.palette_list_scroll = next - visible_rows + 1;
        }
        if (self.palette_list_hwnd) |h| _ = sys.InvalidateRect(h, null, 0);
        if (changed) {
            self.announcePaletteSelection();
            self.previewSelectedPaletteTheme();
            self.refreshPalettePresentation();
        }
        return changed;
    }

    /// Move the list selection up/down one row, scrolling if the new
    /// selection is off-screen. Returns true if the key was consumed.
    pub fn moveListSelection(self: *Host, reverse: bool) bool {
        if (self.overlay_mode != .command_palette) return false;
        if (self.palette_list_ranked_count == 0 or self.palette_list_visible_rows == 0) return false;
        var next: usize = self.palette_list_selected;
        if (reverse) {
            if (next == 0) {
                next = self.palette_list_ranked_count - 1;
            } else {
                next -= 1;
            }
        } else {
            next += 1;
            if (next >= self.palette_list_ranked_count) next = 0;
        }
        _ = self.setPaletteListSelection(next);
        return true;
    }

    /// Stable list identity. Row selection is announced by the native
    /// SelectionItem event, avoiding duplicate Name/Notification speech.
    pub fn buildPaletteListName(_: *const Host, _: []u8) []const u8 {
        return "Command palette results";
    }

    pub fn paletteShortcutLabel(
        self: *const Host,
        descriptor: win32_palette.catalog.Descriptor,
        buf: []u8,
    ) ?[]const u8 {
        if (descriptor.item.shortcut) |shortcut| return shortcut.label;
        return switch (descriptor.payload) {
            .action => |payload| blk: {
                const snapshot_index = payload.snapshot_index orelse break :blk null;
                const snap = self.paletteSnapshot();
                if (snapshot_index >= snap.commands.len) break :blk null;
                const trigger = self.app.config.keybind.set.reverse.get(snap.commands[snapshot_index].action) orelse
                    break :blk null;
                break :blk std.fmt.bufPrint(buf, "{f}", .{trigger}) catch null;
            },
            else => null,
        };
    }

    pub fn buildPaletteRowName(self: *const Host, index: usize, buf: []u8) []const u8 {
        if (index >= self.palette_list_ranked_count) return "Command palette row";
        const catalog = if (self.palette_catalog) |*value| value else return "Command palette row";
        const descriptor = catalog.descriptorFor(self.palette_list_ranked[index]) orelse return "Command palette row";
        var shortcut_buf: [96]u8 = undefined;
        const shortcut = self.paletteShortcutLabel(descriptor, &shortcut_buf);
        const state = if (!descriptor.item.enabled)
            ", unavailable"
        else if (descriptor.item.destructive)
            ", destructive"
        else
            "";
        if (shortcut) |label| {
            return std.fmt.bufPrint(
                buf,
                "{d} of {d}: {s} — {s}, shortcut {s}{s}",
                .{
                    index + 1,
                    self.palette_list_ranked_count,
                    descriptor.item.title,
                    if (descriptor.item.enabled) descriptor.item.subtitle else descriptor.item.disabled_reason orelse "Unavailable",
                    label,
                    state,
                },
            ) catch "Command palette row";
        }
        return std.fmt.bufPrint(
            buf,
            "{d} of {d}: {s} — {s}{s}",
            .{
                index + 1,
                self.palette_list_ranked_count,
                descriptor.item.title,
                if (descriptor.item.enabled) descriptor.item.subtitle else descriptor.item.disabled_reason orelse "Unavailable",
                state,
            },
        ) catch "Command palette row";
    }

    pub fn paletteListUiaState(self: *const Host) win32_uia.PaletteListState {
        return self.paletteListUiaStateWithThreading(self.app.com_initialized);
    }

    pub fn paletteListUiaStateWithThreading(
        self: *const Host,
        use_com_threading: bool,
    ) win32_uia.PaletteListState {
        return .{
            .ctx = @ptrCast(@constCast(self)),
            .name = &paletteListNameThunk,
            .row_count = &paletteListRowCountThunk,
            .selected_index = &paletteListSelectedIndexThunk,
            .row_name = &paletteListRowNameThunk,
            .row_enabled = &paletteListRowEnabledThunk,
            .row_id = &paletteListRowIdThunk,
            .select_row = &paletteListSelectRowThunk,
            .geometry = &paletteListGeometryThunk,
            .use_com_threading = use_com_threading,
        };
    }

    pub fn announcePaletteSelection(self: *const Host) void {
        const provider = self.palette_list_uia_provider orelse return;
        if (self.palette_list_ranked_count > 0) {
            provider.raiseSelectionChanged(@min(self.palette_list_selected, self.palette_list_ranked_count - 1));
        }
    }

    pub fn announcePaletteOutcome(
        self: *const Host,
        notification: win32_uia.events.Notification,
        message: []const u8,
    ) void {
        const provider = self.palette_list_uia_provider orelse return;
        win32_uia.events.raiseNotification(&provider.base, notification, message);
    }

    pub fn abortPaletteAction(self: *Host, message: []const u8) void {
        runUiActionOrLog("palette abort banner failed", self.setBanner(.err, message));
        self.announcePaletteOutcome(.action_aborted, message);
    }

    pub fn showPaletteHelp(self: *Host, message: []const u8) void {
        self.setBanner(.info, message) catch |err| {
            log.warn("palette help banner failed err={}", .{err});
        };
        self.announcePaletteOutcome(.other, message);
    }

    /// Translate a y coordinate (client-area) into an absolute rank
    /// index, or null if the click landed outside a row.
    pub fn paletteRowAtY(self: *const Host, y: i32) ?usize {
        if (y < 0) return null;
        const row_h = self.scaled(palette_row_height);
        if (row_h <= 0) return null;
        const visible_row: usize = @intCast(@divTrunc(y, row_h));
        const absolute = visible_row + self.palette_list_scroll;
        if (absolute >= self.palette_list_ranked_count) return null;
        return absolute;
    }

    /// Dispatch the action at rank index `row`. Must be called from the
    /// palette list's WM_LBUTTONDOWN, where the Host is still alive;
    /// the dispatched action may free the host (`close_window`, etc.)
    /// so no `self` access after `performBindingAction`.
    pub fn invokePaletteRow(self: *Host, row: usize) !void {
        if (row >= self.palette_list_ranked_count) return;
        if (row >= self.palette_list_ranked.len) return;
        const catalog = if (self.palette_catalog) |*value| value else return;
        const descriptor = catalog.descriptorFor(self.palette_list_ranked[row]) orelse return;
        if (!descriptor.item.enabled) {
            try self.setBanner(.err, descriptor.item.disabled_reason orelse "This item is unavailable.");
            if (self.palette_list_uia_provider) |provider| {
                win32_uia.events.raiseNotification(
                    &provider.base,
                    .action_aborted,
                    descriptor.item.disabled_reason orelse "Command unavailable",
                );
            }
            return;
        }

        switch (descriptor.payload) {
            .action => |payload| {
                return self.invokePaletteAction(payload, true);
            },
            .tab => |tab_id| {
                const index = self.findTabIndexById(@intCast(tab_id)) orelse {
                    self.abortPaletteAction("Tab is no longer available; reopen the palette.");
                    return;
                };
                self.hideOverlay();
                _ = self.activateTabIndex(index);
            },
            .pane => |surface_id| {
                const surface = self.app.findSurfaceById(surface_id) orelse {
                    self.abortPaletteAction("Pane is no longer available; reopen the palette.");
                    return;
                };
                self.hideOverlay();
                self.app.activateSurface(surface);
            },
            .profile => |key| {
                const profiles = self.shownProfiles() orelse {
                    self.abortPaletteAction("Profile is no longer available; reopen the palette.");
                    return;
                };
                const index = profileIndexByKey(profiles, key) orelse {
                    self.abortPaletteAction("Profile is no longer available; reopen the palette.");
                    return;
                };
                _ = self.setSelectedProfileIndex(index) catch |err| {
                    log.warn("palette profile selection failed key={s} err={}", .{ key, err });
                    self.abortPaletteAction("Profile selection failed; no profile was opened.");
                    return;
                };
                self.hideOverlay();
                if (!self.openSelectedProfile(.tab)) {
                    self.abortPaletteAction("Profile could not be opened; no terminal was changed.");
                }
            },
            .layout => |name| {
                const owned_name = self.app.core_app.alloc.dupe(u8, name) catch |err| {
                    log.warn("palette layout name copy failed name={s} err={}", .{ name, err });
                    self.abortPaletteAction("Layout could not be prepared.");
                    return;
                };
                defer self.app.core_app.alloc.free(owned_name);
                self.hideOverlay();
                if (!self.app.launchNamedLayout(owned_name, self)) {
                    self.abortPaletteAction("Layout could not be opened.");
                }
            },
            .setting => |key| {
                const field = std.meta.stringToEnum(win32_settings.SettingField, key) orelse {
                    self.abortPaletteAction("Setting is no longer available; reopen the palette.");
                    return;
                };
                self.hideOverlay();
                self.app.settings_window.openField(field) catch |err| {
                    log.warn("palette settings open failed field={} err={}", .{ field, err });
                    self.abortPaletteAction("Settings could not be opened.");
                    return;
                };
            },
            .theme => |name| {
                self.commitPaletteTheme(name) catch |err| {
                    log.warn("palette theme preflight failed theme={s} err={}", .{ name, err });
                    self.abortPaletteAction("Theme could not be prepared; no setting was changed.");
                    return;
                };
            },
            .help => |target| switch (target) {
                .settings => {
                    self.hideOverlay();
                    self.app.settings_window.openField(.font_size) catch |err| {
                        log.warn("palette help settings open failed err={}", .{err});
                        self.abortPaletteAction("Settings help could not be opened.");
                        return;
                    };
                },
                .config_problems => {
                    self.hideOverlay();
                    self.app.settings_window.openSection(.advanced) catch |err| {
                        log.warn("palette config problems open failed err={}", .{err});
                        self.abortPaletteAction("Settings could not be opened.");
                        return;
                    };
                },
                .keyboard_shortcuts => self.showPaletteHelp("Keyboard shortcuts are configured in Settings > Keybindings."),
                .configuration => self.showPaletteHelp("Open Settings, then Advanced, to edit the configuration file."),
                .troubleshooting => self.showPaletteHelp("Run noctty +diagnostic-bundle when reporting a problem."),
                .diagnostics => self.showPaletteHelp("Run noctty +diagnostic-bundle to export a redacted support bundle."),
                .accessibility => self.showPaletteHelp("Keyboard: Ctrl+Page Up or Page Down changes tabs; Ctrl+Shift+Backslash splits right; Ctrl+Shift+E splits down; Alt+Arrow moves between panes."),
            },
            .recent_command => |payload| return self.invokePaletteAction(payload, false),
        }
    }

    pub fn appendInstalledThemesToPalette(self: *Host, catalog: *PaletteCatalog) void {
        const alloc = self.app.core_app.alloc;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        const installed = themepkg.list(alloc, arena.allocator()) catch |err| {
            log.warn("palette theme enumeration failed err={}", .{err});
            return;
        };
        self.palette_installed_themes = installed;
        if (installed.len == 0) return;

        const reserve_items: usize = win32_palette.catalog.reviewed_help.len + self.app.palette_mru.len;
        const used_items = catalog.items().len;
        const free_items = catalog.capacity() -| used_items;
        const theme_item_limit = free_items -| reserve_items;
        const theme_label_limit = self.palette_catalog_labels.len -| self.palette_catalog_label_count;
        const theme_limit = @min(installed.len, @min(theme_item_limit, theme_label_limit));
        if (theme_limit == 0) return;

        var entries = std.ArrayList(win32_palette.catalog.ThemeEntry).empty;
        defer entries.deinit(alloc);
        entries.ensureTotalCapacity(alloc, theme_limit) catch |err| {
            log.warn("palette theme capacity failed err={}", .{err});
            return;
        };
        for (installed[0..theme_limit]) |theme| {
            entries.appendAssumeCapacity(.{
                .name = theme.name,
                .display_name = self.storePaletteCatalogLabel(theme.name),
                .description = switch (theme.location) {
                    .user, .legacy_user => "User theme",
                    .resources => "Bundled theme",
                },
                .enabled = true,
            });
        }
        _ = catalog.appendThemesBounded(entries.items, theme_limit) catch |err| {
            log.warn("palette theme batch rejected err={}", .{err});
        };
    }

    pub fn appendSavedLayoutsToPalette(self: *Host, catalog: *PaletteCatalog) void {
        const alloc = self.app.core_app.alloc;
        const directory = self.app.namedLayoutsDirectoryPath() orelse return;
        defer alloc.free(directory);
        // Only help and recent-command rows are still pending at this point;
        // actions, tabs, panes, profiles, settings, and themes are already in.
        const reserve_items = win32_palette.catalog.reviewed_help.len +
            self.app.palette_mru.len;
        const free_items = (catalog.capacity() -| catalog.items().len) -| reserve_items;
        const free_labels = self.palette_catalog_labels.len -| self.palette_catalog_label_count;
        const limit = @min(win32_layouts.max_palette_entries, @min(free_items, free_labels));
        if (limit == 0) return;

        const names = win32_layouts.listNamesAlloc(alloc, directory, limit) catch |err| {
            log.warn("palette layout enumeration failed path={s} err={}", .{ directory, err });
            return;
        };
        self.palette_layout_names = names;
        for (names) |name| {
            var title_buffer: [palette_catalog_label_bytes]u8 = undefined;
            const raw_title = std.fmt.bufPrint(
                &title_buffer,
                "Launch layout: {s}",
                .{name},
            ) catch continue;
            _ = self.appendPaletteDescriptor(.{
                .item = .{
                    .id = win32_palette.catalog.stableStringId(.layout, name),
                    .title = self.storePaletteCatalogLabel(raw_title),
                    .subtitle = "Layout",
                    .keywords = "layout workspace window tabs splits launch",
                },
                .payload = .{ .layout = name },
            });
        }
    }

    pub fn clearPaletteInstalledThemes(self: *Host) void {
        const installed = self.palette_installed_themes orelse return;
        self.palette_installed_themes = null;
        themepkg.freeList(self.app.core_app.alloc, installed);
    }

    pub fn clearPaletteLayoutNames(self: *Host) void {
        const names = self.palette_layout_names orelse return;
        self.palette_layout_names = null;
        for (names) |name| self.app.core_app.alloc.free(name);
        self.app.core_app.alloc.free(names);
    }

    pub fn selectedPaletteThemeName(self: *Host) ?[]const u8 {
        if (self.overlay_mode != .command_palette) return null;
        if (self.palette_list_ranked_count == 0) return null;
        const row = @min(self.palette_list_selected, self.palette_list_ranked_count - 1);
        const catalog = if (self.palette_catalog) |*value| value else return null;
        const descriptor = catalog.descriptorFor(self.palette_list_ranked[row]) orelse return null;
        return switch (descriptor.payload) {
            .theme => |name| name,
            else => null,
        };
    }

    pub fn invokePaletteAction(
        self: *Host,
        payload: win32_palette.catalog.ActionPayload,
        record_mru: bool,
    ) !void {
        if (payload.tab_transfer) |transfer| {
            const source_index = self.findTabIndexById(@intCast(transfer.source_tab)) orelse {
                self.abortPaletteAction("Tab move is no longer available; reopen the palette.");
                return;
            };
            const target = self.app.findSurfaceById(transfer.target_pane) orelse {
                self.abortPaletteAction("Tab move target is no longer available; reopen the palette.");
                return;
            };
            const target_found = self.app.findTabForSurface(target) orelse {
                self.abortPaletteAction("Tab move target is no longer available; reopen the palette.");
                return;
            };
            if (target_found.host != self or target_found.index != self.active_tab) {
                self.abortPaletteAction("Tab move target changed; reopen the palette.");
                return;
            }
            self.tab_drop_target_surface = target;
            self.tab_drop_operation = switch (transfer.direction) {
                .left => .split_left,
                .right => .split_right,
                .up => .split_up,
                .down => .split_down,
            };
            if (!self.commitTabDropSplit(source_index)) {
                self.abortPaletteAction("Tab move could not be completed; no layout was changed.");
                return;
            }
            self.hideOverlay();
            return;
        }
        const snap = self.paletteSnapshot();
        const snapshot_index = payload.snapshot_index orelse {
            self.abortPaletteAction("Command is no longer available; reopen the palette.");
            return;
        };
        if (snapshot_index >= snap.commands.len or snapshot_index >= snap.cvals.len) {
            self.abortPaletteAction("Command is no longer available; reopen the palette.");
            return;
        }
        const current_text = std.mem.span(snap.cvals[snapshot_index].action);
        if (!std.mem.eql(u8, current_text, payload.action)) {
            self.abortPaletteAction("Command changed; reopen the palette and try again.");
            return;
        }
        const action = snap.commands[snapshot_index].action;
        const surface = self.activeSurface() orelse {
            self.abortPaletteAction("No active terminal is available for this command.");
            return;
        };
        if (record_mru) self.app.pushPaletteMru(current_text) catch |err| {
            std.log.warn("palette MRU push failed err={}", .{err});
        };
        const outcome_provider = if (self.palette_list_uia_provider) |provider| blk: {
            _ = provider.base.vtbl.AddRef(&provider.base);
            break :blk &provider.base;
        } else null;
        defer if (outcome_provider) |provider| {
            _ = provider.vtbl.Release(provider);
        };
        self.hideOverlay();
        runUiActionOrLog("palette layout refresh failed", self.layout());
        if (action == .new_tab) {
            self.postDeferredNewTab();
            return;
        }
        // A command the user runs on the pane, as a key would.
        surface.noteProgramInput();
        const performed = surface.core_surface.performBindingAction(action) catch |err| {
            if (outcome_provider) |provider| {
                win32_uia.events.raiseNotification(
                    provider,
                    .action_aborted,
                    "Command failed; no action was completed.",
                );
            }
            return err;
        };
        // Do NOT touch `self` after dispatch — the host may be freed. The one
        // exception is an undo or redo that did nothing: nothing was freed, and
        // a palette request, unlike the performable key, owes an answer.
        if (!performed and (action == .undo or action == .redo)) {
            runUiActionOrLog(
                "palette undo banner failed",
                self.setBanner(.info, if (action == .undo) "Nothing to undo." else "Nothing to redo."),
            );
        }
    }

    /// Scroll three rows per notch, retaining high-resolution fractions.
    pub fn scrollPaletteList(self: *Host, delta: i16) void {
        self.scrollPaletteListAt(delta, sys.GetTickCount64());
    }

    pub fn scrollPaletteListAt(self: *Host, delta: i16, now_ms: u64) void {
        const visible_rows = self.palette_list_visible_rows;
        if (visible_rows == 0 or self.palette_list_ranked_count <= visible_rows) {
            self.palette_wheel_steps = .{};
            return;
        }
        // Chrome has a fixed three-row notch, independent of terminal cell
        // size and the surface's configured wheel multiplier.
        const step = self.palette_wheel_steps.add(win32_input.chromeWheelDelta(false, delta, 3), now_ms);
        if (step == 0) return;
        const max_scroll = self.palette_list_ranked_count - visible_rows;
        var next: isize = @as(isize, @intCast(self.palette_list_scroll)) - step;
        if (next < 0) next = 0;
        if (next > @as(isize, @intCast(max_scroll))) next = @intCast(max_scroll);
        const new_scroll: usize = @intCast(next);
        if (new_scroll == 0 or new_scroll == max_scroll) self.palette_wheel_steps = .{};
        if (new_scroll == self.palette_list_scroll) return;
        self.palette_list_scroll = new_scroll;
        // Clamp the selected row into the visible window. Without this,
        // Enter invokes whatever row the selection *used* to point at —
        // possibly an off-screen action the user has no idea they're
        // launching. UIA Name updates follow from the reassignment.
        const previous_selection = self.palette_list_selected;
        const visible_end = new_scroll + visible_rows;
        if (self.palette_list_selected < new_scroll) {
            self.palette_list_selected = new_scroll;
        } else if (self.palette_list_selected >= visible_end) {
            self.palette_list_selected = visible_end - 1;
        }
        if (self.palette_list_hwnd) |h| _ = sys.InvalidateRect(h, null, 0);
        if (self.palette_list_selected != previous_selection) {
            self.announcePaletteSelection();
            self.previewSelectedPaletteTheme();
            self.refreshPalettePresentation();
        }
    }

    test "chrome pointer palette scroll retains small deltas and resets at bounds" {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
        });
        defer session.deinit();
        host.palette_list_ranked_count = 20;
        host.palette_list_visible_rows = 5;
        host.palette_list_selected = 3;
        for (0..3) |i| host.scrollPaletteListAt(-10, i);
        try std.testing.expectEqual(@as(usize, 0), host.palette_list_scroll);
        host.scrollPaletteListAt(-10, 3);
        try std.testing.expectEqual(@as(usize, 1), host.palette_list_scroll);
        try std.testing.expectEqual(@as(usize, 3), host.palette_list_selected);
        host.scrollPaletteListAt(-120, 4);
        try std.testing.expectEqual(@as(usize, 4), host.palette_list_scroll);
        try std.testing.expectEqual(@as(usize, 4), host.palette_list_selected);
        host.scrollPaletteListAt(120, 5);
        try std.testing.expectEqual(@as(usize, 1), host.palette_list_scroll);
        host.scrollPaletteListAt(120, 6);
        try std.testing.expectEqual(@as(usize, 0), host.palette_list_scroll);
        try std.testing.expectEqual(@as(i32, 0), host.palette_wheel_steps.remainder);
        host.palette_list_ranked_count = 2;
        host.palette_wheel_steps.remainder = 60;
        host.scrollPaletteListAt(-10, 7);
        try std.testing.expectEqual(@as(i32, 0), host.palette_wheel_steps.remainder);
    }

    test "chrome pointer gesture resets after non-wheel palette selection" {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
        });
        defer session.deinit();
        host.overlay_mode = .command_palette;
        host.palette_list_ranked_count = 20;
        host.palette_list_visible_rows = 5;
        host.palette_list_selected = 5;
        host.palette_list_scroll = 4;
        host.palette_wheel_steps.remainder = -90;
        try std.testing.expect(host.setPaletteListSelection(0));
        try std.testing.expectEqual(@as(usize, 0), host.palette_list_scroll);
        try std.testing.expectEqual(@as(i32, 0), host.palette_wheel_steps.remainder);
        host.palette_wheel_steps.remainder = -90;
        try std.testing.expect(host.setPaletteListSelection(3));
        try std.testing.expectEqual(@as(i32, 0), host.palette_wheel_steps.remainder);
    }

    test "chrome pointer gesture resets when palette layout hides the list" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(paletteHideWheelTestBody);
    }

    fn paletteHideWheelTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        // A real native child is enough to exercise the production layout
        // visibility path; no custom palette class or ranked rows are needed.
        host.palette_list_hwnd = window.pane;
        defer host.palette_list_hwnd = null;
        host.palette_wheel_steps.remainder = 60;
        var changed = false;
        _ = host.layoutChromeForRect(window.content, &changed);
        try std.testing.expectEqual(@as(i32, 0), host.palette_wheel_steps.remainder);
    }

    /// BeginPaint/EndPaint over the list child HWND. Each row shows
    /// title | action | keybind hint. The selected row (Enter target)
    /// gets the accent highlight.
    pub fn paintPaletteList(self: *Host) void {
        const hwnd = self.palette_list_hwnd orelse return;
        var ps: PAINTSTRUCT = undefined;
        const hdc = sys.BeginPaint(hwnd, &ps);
        defer _ = sys.EndPaint(hwnd, &ps);

        var rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &rect) == 0) return;

        const theme = &self.app.resolved_theme;
        fillSolidRect(hdc, rect, theme.overlay_bg);
        defer drawRectBorder(hdc, rect, theme.overlay_border, @max(1, self.scaled(1)));

        if (self.palette_list_ranked_count == 0) return;

        const catalog = if (self.palette_catalog) |*value| value else return;
        const row_h = self.scaled(palette_row_height);
        const padding = self.scaled(12);

        _ = sys.SetBkMode(hdc, c.TRANSPARENT);
        const old_font: ?HGDIOBJ = if (self.chrome_font) |f| sys.SelectObject(hdc, f) else null;
        defer {
            if (old_font) |f| _ = sys.SelectObject(hdc, f);
        }

        const visible_end = @min(
            self.palette_list_scroll + self.palette_list_visible_rows,
            self.palette_list_ranked_count,
        );
        var i = self.palette_list_scroll;
        while (i < visible_end) : (i += 1) {
            const y_top: i32 = @intCast((i - self.palette_list_scroll) * @as(usize, @intCast(row_h)));
            const row_rect: RECT = .{
                .left = 0,
                .top = y_top,
                .right = rect.right,
                .bottom = y_top + row_h,
            };
            const is_selected = i == self.palette_list_selected;
            if (is_selected) {
                fillSolidRect(hdc, row_rect, theme.button_active_bg);
            }
            if (i >= self.palette_list_ranked.len) break;
            const descriptor = catalog.descriptorFor(self.palette_list_ranked[i]) orelse continue;
            const item = descriptor.item;

            const title_color = paletteRowTitleColor(
                item.destructive,
                is_selected,
                theme.text_primary,
                theme.button_active_fg,
                theme.error_fg,
            );
            const secondary_color = if (is_selected) theme.button_active_fg else theme.text_secondary;
            const columns = paletteRowColumns(
                row_rect,
                padding,
                self.scaled(200),
                self.scaled(80),
                self.scaled(140),
            );

            if (columns.title.right > columns.title.left) {
                drawPaletteRowText(hdc, item.title, columns.title, title_color);
            }
            if (columns.subtitle.right > columns.subtitle.left) {
                drawPaletteRowText(
                    hdc,
                    if (item.enabled) item.subtitle else item.disabled_reason orelse "Unavailable",
                    columns.subtitle,
                    secondary_color,
                );
            }

            // Keybind hint: look up the primary trigger for this action
            // in the reverse index that `Binding.Set` already maintains.
            // Format into a stack buffer — the per-frame allocation
            // would otherwise stack up at every keystroke's WM_PAINT.
            var hint_buf: [96]u8 = undefined;
            const hint = self.paletteShortcutLabel(descriptor, &hint_buf);
            if (hint) |hint_text| if (columns.shortcut.right > columns.shortcut.left) {
                drawPaletteRowText(
                    hdc,
                    hint_text,
                    columns.shortcut,
                    secondary_color,
                );
            };
        }
    }

    pub fn clearOverlayCompletion(self: *Host) void {
        if (self.overlay_completion_seed) |value| self.app.core_app.alloc.free(value);
        if (self.overlay_completion_value) |value| self.app.core_app.alloc.free(value);
        self.overlay_completion_seed = null;
        self.overlay_completion_value = null;
        self.overlay_completion_result_id = null;
    }

    pub fn syncOverlayCompletionState(self: *Host) !void {
        if (self.overlay_mode != .command_palette) {
            self.clearOverlayCompletion();
            return;
        }
        _ = self.overlay_edit_hwnd orelse {
            self.clearOverlayCompletion();
            return;
        };
        const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");
        if (self.overlay_completion_value) |value| {
            if (std.mem.eql(u8, value, text)) return;
        }
        self.clearOverlayCompletion();
    }

    pub fn completeCommandPalette(self: *Host, reverse: bool) !bool {
        if (self.overlay_mode != .command_palette) return false;
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const alloc = self.app.core_app.alloc;

        // `setOverlayEditText` replaces `cached_overlay_edit`; own the
        // query slices before deriving completion state from them.
        const text_raw = try overlayEditText(self);
        const trimmed = std.mem.trim(u8, text_raw, " \t\r\n");
        const text_owned = try alloc.dupe(u8, trimmed);
        defer alloc.free(text_owned);

        const seed_owned: []const u8 = blk: {
            if (self.overlay_completion_seed) |value| {
                if (self.overlay_completion_value) |current| {
                    if (std.mem.eql(u8, current, text_owned)) {
                        break :blk try alloc.dupe(u8, value);
                    }
                }
            }
            break :blk try alloc.dupe(u8, text_owned);
        };
        defer alloc.free(seed_owned);

        const candidate = self.richPaletteCompletionCandidate(
            seed_owned,
            text_owned,
            self.overlay_completion_result_id,
            reverse,
        ) orelse return false;
        // `candidate` borrows from the current rich catalog. Preserve the
        // completion state before `syncCommandPaletteBanner` rebuilds it.
        _ = try self.setOverlayEditText(candidate.text);
        _ = sys.SendMessageW(edit_hwnd, c.EM_SETSEL, 0, -1);
        if (!ownedStringEquals(self.overlay_completion_seed, seed_owned)) {
            try appendOwnedString(alloc, &self.overlay_completion_seed, seed_owned);
        }
        if (!ownedStringEquals(self.overlay_completion_value, candidate.text)) {
            try appendOwnedString(alloc, &self.overlay_completion_value, candidate.text);
        }
        self.overlay_completion_result_id = candidate.id;
        _ = try self.syncCommandPaletteBanner();
        return true;
    }

    pub fn richPaletteCompletionCandidate(
        self: *const Host,
        seed: []const u8,
        current: []const u8,
        current_id: ?PaletteStableId,
        reverse: bool,
    ) ?PaletteCompletion {
        const catalog = if (self.palette_catalog) |*value| value else return null;
        var ranked_buf: [win32_palette.max_ranked]PaletteRanked = undefined;
        const ranked = catalog.rank(
            seed,
            .{ .max_results = ranked_buf.len },
            &ranked_buf,
        );
        if (ranked.len == 0) return null;

        var current_index: ?usize = null;
        for (ranked, 0..) |result, index| {
            const descriptor = catalog.descriptorFor(result) orelse continue;
            const id_matches = if (current_id) |id| result.id.eql(id) else false;
            if (id_matches or (current_id == null and
                std.mem.eql(u8, paletteCompletionText(descriptor), current)))
            {
                current_index = index;
                break;
            }
        }
        const target = if (current_index) |index|
            if (reverse)
                (index + ranked.len - 1) % ranked.len
            else
                (index + 1) % ranked.len
        else if (reverse)
            ranked.len - 1
        else
            0;
        const descriptor = catalog.descriptorFor(ranked[target]) orelse return null;
        return .{
            .text = paletteCompletionText(descriptor),
            .id = ranked[target].id,
        };
    }

    pub fn syncCommandPaletteBanner(self: *Host) !bool {
        if (self.overlay_mode != .command_palette) return false;
        _ = self.overlay_edit_hwnd orelse return false;
        self.rebuildPaletteList();
        // Query guidance comes from the same rich catalog that owns the
        // visible rows. Clear action-outcome banners from the previous query;
        // `syncOverlayHint`/paint then render the current rich presentation.
        try self.setBanner(.none, null);
        _ = try self.syncOverlayLabel();
        _ = try self.syncOverlayHint();
        _ = try self.syncOverlayButtons();
        self.invalidateOverlayText();
        return true;
    }
};
