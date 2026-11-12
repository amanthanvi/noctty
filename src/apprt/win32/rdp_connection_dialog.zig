//! The modal window that edits one Remote Desktop connection of the
//! Profiles page: its name, server, port, user name, password and its own
//! quality settings (`terminals_import.RdpOptions`, each "Default" to take
//! the config's). Settings writes what it returns into the draft and keeps
//! the login apart from the config (`profile_credentials`).
//!
//! Nothing here logs a value the person typed.
const std = @import("std");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const terminals_import = @import("terminals_import.zig");

const BOOL = win32_types.BOOL;
const HINSTANCE = win32_types.HINSTANCE;
const HWND = win32_types.HWND;
const LPARAM = win32_types.LPARAM;
const LPCWSTR = win32_types.LPCWSTR;
const LRESULT = win32_types.LRESULT;
const UINT = win32_types.UINT;
const WPARAM = win32_types.WPARAM;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// What the dialog edits. In: the connection as it is (empty for a new
/// one). Out, when the person pressed OK: what they typed. All text lives in
/// the `alloc` given to `edit`.
pub const Connection = struct {
    name: []const u8 = "",
    server: []const u8 = "",
    port: u16 = 3389,
    user: []const u8 = "",
    /// Out only: a password typed in; null leaves the kept one as it is.
    password: ?[]const u8 = null,
    /// In only: a password is kept, so the field says leaving it blank
    /// keeps it.
    has_password: bool = false,
    options: terminals_import.RdpOptions = .{},
};

extern "user32" fn DialogBoxIndirectParamW(hInstance: ?HINSTANCE, template: *const anyopaque, parent: ?HWND, proc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize, init: LPARAM) callconv(.winapi) isize;
extern "user32" fn EndDialog(hDlg: HWND, result: isize) callconv(.winapi) BOOL;
extern "user32" fn GetDlgItem(hDlg: HWND, id: i32) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn SetWindowTextW(hWnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(hWnd: HWND, text: [*]u16, max: i32) callconv(.winapi) i32;
extern "user32" fn MessageBoxW(hwnd: ?HWND, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;

const IDOK: u16 = 1;
const IDCANCEL: u16 = 2;
const id_name: u16 = 110;
const id_server: u16 = 111;
const id_port: u16 = 112;
const id_user: u16 = 113;
const id_password: u16 = 114;
const id_colors: u16 = 115;
const id_compression: u16 = 116;
const id_experience: u16 = 117;
const id_password_note: u16 = 118;
const id_certificates: u16 = 119;

const DWLP_USER: i32 = @sizeOf(usize) * 2;
const WM_INITDIALOG: UINT = 0x0110;
const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const CB_ADDSTRING: UINT = 0x0143;
const CB_GETCURSEL: UINT = 0x0147;
const CB_SETCURSEL: UINT = 0x014E;
const EM_LIMITTEXT: UINT = 0x00C5;

const color_labels = [_][:0]const u16{ L("Default (Settings)"), L("32 bits (true color)"), L("24 bits"), L("16 bits (high color)"), L("15 bits") };
const color_values = [_]?terminals_import.ColorDepth{ null, .@"32", .@"24", .@"16", .@"15" };
const compression_labels = [_][:0]const u16{ L("Default (Settings)"), L("On"), L("Off") };
const compression_values = [_]?bool{ null, true, false };
const experience_labels = [_][:0]const u16{ L("Default (Settings)"), L("Fast (no wallpaper, themes or animations)"), L("Balanced (themes and font smoothing)"), L("Rich (everything)") };
const experience_values = [_]?terminals_import.Experience{ null, .fast, .balanced, .rich };
const certificate_labels = [_][:0]const u16{ L("Default (Settings)"), L("Connect without asking"), L("Ask (Windows' warning)") };
const certificate_values = [_]?bool{ null, true, false };

const State = struct {
    alloc: Allocator,
    connection: *Connection,
    title: [:0]const u16,
};

/// Edit `connection` in a modal window over `owner`. Returns whether OK was
/// pressed; `connection` then holds what was typed, in `alloc`.
pub fn edit(alloc: Allocator, owner: ?HWND, connection: *Connection, title: [:0]const u16) Allocator.Error!bool {
    const template = try buildTemplate(alloc);
    defer alloc.free(template);
    var state: State = .{ .alloc = alloc, .connection = connection, .title = title };
    return DialogBoxIndirectParamW(GetModuleHandleW(null), template.ptr, owner, dialogProc, @bitCast(@intFromPtr(&state))) == IDOK;
}

const Template = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    alloc: Allocator,

    fn int(self: *Template, comptime I: type, value: I) Allocator.Error!void {
        var buf: [@sizeOf(I)]u8 = undefined;
        std.mem.writeInt(I, &buf, value, .little);
        try self.bytes.appendSlice(self.alloc, &buf);
    }
    fn wstr(self: *Template, text: []const u16) Allocator.Error!void {
        for (text) |unit| try self.int(u16, unit);
        try self.int(u16, 0);
    }
    fn item(self: *Template, style: u32, x: i16, y: i16, cx: i16, cy: i16, id: u16, atom: u16, title: []const u16) Allocator.Error!void {
        while (self.bytes.items.len % 4 != 0) try self.bytes.append(self.alloc, 0);
        try self.int(u32, style);
        try self.int(u32, 0);
        try self.int(i16, x);
        try self.int(i16, y);
        try self.int(i16, cx);
        try self.int(i16, cy);
        try self.int(u16, id);
        try self.int(u16, 0xFFFF);
        try self.int(u16, atom);
        try self.wstr(title);
        try self.int(u16, 0);
    }
};

fn buildTemplate(alloc: Allocator) Allocator.Error![]align(4) u8 {
    var t: Template = .{ .alloc = alloc };
    defer t.bytes.deinit(alloc);
    const WS_CHILD: u32 = 0x40000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_TABSTOP: u32 = 0x00010000;
    const WS_GROUP: u32 = 0x00020000;
    const WS_BORDER: u32 = 0x00800000;
    const WS_VSCROLL: u32 = 0x00200000;
    const child = WS_CHILD | WS_VISIBLE;
    const ES_AUTOHSCROLL: u32 = 0x80;
    const ES_NUMBER: u32 = 0x2000;
    const ES_PASSWORD: u32 = 0x20;
    const CBS_DROPDOWNLIST: u32 = 0x3;
    const BS_DEFPUSHBUTTON: u32 = 0x1;
    const button: u16 = 0x0080;
    const edit_atom: u16 = 0x0081;
    const static: u16 = 0x0082;
    const combo: u16 = 0x0085;

    const w: i16 = 280;
    const h: i16 = 232;
    const label_w: i16 = 86;
    const field_x: i16 = 7 + label_w + 4;
    const field_w: i16 = w - field_x - 7;
    const count: u16 = 9 * 2 + 1 + 2;
    try t.int(u32, 0x80000000 | 0x00C00000 | 0x00080000 | 0x80 | 0x40 | 0x800); // popup, caption, sysmenu, modal frame, setfont, center
    try t.int(u32, 0);
    try t.int(u16, count);
    try t.int(i16, 0);
    try t.int(i16, 0);
    try t.int(i16, w);
    try t.int(i16, h);
    try t.int(u16, 0);
    try t.int(u16, 0);
    try t.wstr(L("Remote Desktop connection"));
    try t.int(u16, 9);
    try t.wstr(L("Segoe UI"));

    const Row = struct { label: []const u16, id: u16, kind: enum { text, number, password, choice } };
    const rows = [_]Row{
        .{ .label = L("&Name"), .id = id_name, .kind = .text },
        .{ .label = L("&Server"), .id = id_server, .kind = .text },
        .{ .label = L("P&ort"), .id = id_port, .kind = .number },
        .{ .label = L("&User name"), .id = id_user, .kind = .text },
        .{ .label = L("Pass&word"), .id = id_password, .kind = .password },
        .{ .label = L("&Colors"), .id = id_colors, .kind = .choice },
        .{ .label = L("Com&pression"), .id = id_compression, .kind = .choice },
        .{ .label = L("&Visual quality"), .id = id_experience, .kind = .choice },
        .{ .label = L("Unverified ser&ver"), .id = id_certificates, .kind = .choice },
    };
    var y: i16 = 9;
    for (rows) |row| {
        try t.item(child, 7, y + 2, label_w, 9, 0xFFFF, static, row.label);
        const style: u32 = switch (row.kind) {
            .text => child | WS_TABSTOP | WS_GROUP | WS_BORDER | ES_AUTOHSCROLL,
            .number => child | WS_TABSTOP | WS_GROUP | WS_BORDER | ES_AUTOHSCROLL | ES_NUMBER,
            .password => child | WS_TABSTOP | WS_GROUP | WS_BORDER | ES_AUTOHSCROLL | ES_PASSWORD,
            .choice => child | WS_TABSTOP | WS_GROUP | WS_VSCROLL | CBS_DROPDOWNLIST,
        };
        const field_h: i16 = if (row.kind == .choice) 90 else 12;
        try t.item(style, field_x, y, if (row.kind == .number) 50 else field_w, field_h, row.id, if (row.kind == .choice) combo else edit_atom, L(""));
        y += if (row.kind == .password) 26 else 18;
    }
    // Under the password field: what leaving it blank does.
    try t.item(child, field_x, 9 + 18 * 4 + 14, field_w, 9, id_password_note, static, L(""));
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_DEFPUSHBUTTON, w - 7 - 50 - 4 - 50, h - 21, 50, 14, IDOK, button, L("OK"));
    try t.item(child | WS_TABSTOP, w - 7 - 50, h - 21, 50, 14, IDCANCEL, button, L("Cancel"));

    const out = try alloc.alignedAlloc(u8, .@"4", t.bytes.items.len);
    @memcpy(out, t.bytes.items);
    return out;
}

fn stateOf(hwnd: HWND) ?*State {
    const raw = GetWindowLongPtrW(hwnd, DWLP_USER);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn setText(hwnd: HWND, id: u16, alloc: Allocator, text: []const u8) void {
    const control = GetDlgItem(hwnd, id) orelse return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return;
    defer alloc.free(wide);
    _ = SetWindowTextW(control, wide.ptr);
}

/// The control's text, trimmed, in `alloc`.
fn readText(hwnd: HWND, id: u16, alloc: Allocator) ?[]u8 {
    const control = GetDlgItem(hwnd, id) orelse return null;
    var buf: [1024]u16 = undefined;
    const len = GetWindowTextW(control, &buf, buf.len);
    const text = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..@intCast(@max(0, len))]) catch return null;
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == text.len) return text;
    const copy = alloc.dupe(u8, trimmed) catch return null;
    alloc.free(text);
    return copy;
}

fn fillCombo(hwnd: HWND, id: u16, labels: []const [:0]const u16, selected: usize) void {
    const control = GetDlgItem(hwnd, id) orelse return;
    for (labels) |label| _ = SendMessageW(control, CB_ADDSTRING, 0, @bitCast(@intFromPtr(label.ptr)));
    _ = SendMessageW(control, CB_SETCURSEL, selected, 0);
}

fn comboIndex(hwnd: HWND, id: u16) usize {
    const control = GetDlgItem(hwnd, id) orelse return 0;
    const raw = SendMessageW(control, CB_GETCURSEL, 0, 0);
    return if (raw < 0) 0 else @intCast(raw);
}

fn indexOf(comptime T: type, values: []const T, value: T) usize {
    for (values, 0..) |candidate, i| if (std.meta.eql(candidate, value)) return i;
    return 0;
}

fn refuse(hwnd: HWND, id: u16, message: [:0]const u16) void {
    _ = MessageBoxW(hwnd, message.ptr, L("Remote Desktop connection"), 0x30);
    if (GetDlgItem(hwnd, id)) |control| _ = SetFocus(control);
}

fn dialogProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize {
    switch (msg) {
        WM_INITDIALOG => {
            _ = SetWindowLongPtrW(hwnd, DWLP_USER, lparam);
            const state = stateOf(hwnd) orelse return 1;
            const conn = state.connection;
            const a = state.alloc;
            _ = SetWindowTextW(hwnd, state.title.ptr);
            setText(hwnd, id_name, a, conn.name);
            setText(hwnd, id_server, a, conn.server);
            var port_buf: [8]u8 = undefined;
            setText(hwnd, id_port, a, std.fmt.bufPrint(&port_buf, "{d}", .{conn.port}) catch "3389");
            setText(hwnd, id_user, a, conn.user);
            setText(hwnd, id_password_note, a, if (conn.has_password) "Blank keeps the saved password." else "No password saved: Windows will ask.");
            if (GetDlgItem(hwnd, id_port)) |port| _ = SendMessageW(port, EM_LIMITTEXT, 5, 0);
            fillCombo(hwnd, id_colors, &color_labels, indexOf(?terminals_import.ColorDepth, &color_values, conn.options.colors));
            fillCombo(hwnd, id_compression, &compression_labels, indexOf(?bool, &compression_values, conn.options.compression));
            fillCombo(hwnd, id_experience, &experience_labels, indexOf(?terminals_import.Experience, &experience_values, conn.options.experience));
            fillCombo(hwnd, id_certificates, &certificate_labels, indexOf(?bool, &certificate_values, conn.options.trust_certificates));
            return 1;
        },
        WM_COMMAND => {
            const id: u16 = @truncate(wparam);
            switch (id) {
                IDOK => {
                    const state = stateOf(hwnd) orelse return 1;
                    const a = state.alloc;
                    const name = readText(hwnd, id_name, a) orelse return 1;
                    if (name.len == 0) {
                        refuse(hwnd, id_name, L("Type a name for the connection."));
                        return 1;
                    }
                    const server = readText(hwnd, id_server, a) orelse return 1;
                    if (!terminals_import.validServer(server)) {
                        refuse(hwnd, id_server, L("Type the server as a host name or an IP address."));
                        return 1;
                    }
                    const port_text = readText(hwnd, id_port, a) orelse return 1;
                    const port = std.fmt.parseInt(u16, port_text, 10) catch 0;
                    if (port == 0) {
                        refuse(hwnd, id_port, L("Type a port from 1 to 65535."));
                        return 1;
                    }
                    const user = readText(hwnd, id_user, a) orelse return 1;
                    const password_control = GetDlgItem(hwnd, id_password);
                    var password: ?[]const u8 = null;
                    if (password_control) |control| {
                        var buf: [512]u16 = undefined;
                        const len = GetWindowTextW(control, &buf, buf.len);
                        if (len > 0) password = std.unicode.utf16LeToUtf8Alloc(a, buf[0..@intCast(len)]) catch null;
                        @memset(&buf, 0);
                    }
                    state.connection.* = .{
                        .name = name,
                        .server = server,
                        .port = port,
                        .user = user,
                        .password = password,
                        .has_password = state.connection.has_password,
                        .options = .{
                            .colors = color_values[@min(comboIndex(hwnd, id_colors), color_values.len - 1)],
                            .compression = compression_values[@min(comboIndex(hwnd, id_compression), compression_values.len - 1)],
                            .experience = experience_values[@min(comboIndex(hwnd, id_experience), experience_values.len - 1)],
                            .trust_certificates = certificate_values[@min(comboIndex(hwnd, id_certificates), certificate_values.len - 1)],
                        },
                    };
                    _ = EndDialog(hwnd, IDOK);
                    return 1;
                },
                IDCANCEL => {
                    _ = EndDialog(hwnd, IDCANCEL);
                    return 1;
                },
                else => return 0,
            }
        },
        WM_CLOSE => {
            _ = EndDialog(hwnd, IDCANCEL);
            return 1;
        },
        else => return 0,
    }
}

test "rdp connection dialog: the template is DWORD aligned and counts its items" {
    const template = try buildTemplate(std.testing.allocator);
    defer std.testing.allocator.free(template);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(template.ptr) % 4);
    try std.testing.expectEqual(@as(u16, 9 * 2 + 1 + 2), std.mem.readInt(u16, template[8..10], .little));
}
