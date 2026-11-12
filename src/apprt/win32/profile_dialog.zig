//! The modal window that edits one terminal profile of the Profiles page:
//! its name, command line, starting folder, zoom (font size), whether it
//! opens as administrator, and its variables (one `NAME=VALUE` a line).
//! Settings checks what it returns and writes it into the draft; the zoom
//! and the administrator choice are kept as the profile's reserved
//! variables (`windows_shell.font_size_env`, `elevated_env`).
//!
//! Nothing here logs a value the person typed.
const std = @import("std");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");

const BOOL = win32_types.BOOL;
const HINSTANCE = win32_types.HINSTANCE;
const HWND = win32_types.HWND;
const LPARAM = win32_types.LPARAM;
const LPCWSTR = win32_types.LPCWSTR;
const LRESULT = win32_types.LRESULT;
const UINT = win32_types.UINT;
const WPARAM = win32_types.WPARAM;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// What the window edits. In: the profile as it is (or a preset's command
/// line for a new one). Out, after OK: what was typed, in the `alloc` given
/// to `edit`. `variables` is the text of the Variables field: one
/// `NAME=VALUE` a line.
pub const Profile = struct {
    name: []const u8 = "",
    command: []const u8 = "",
    folder: []const u8 = "",
    /// Points; empty for the config's.
    font_size: []const u8 = "",
    elevated: bool = false,
    variables: []const u8 = "",
};

/// Checks the caller makes on OK: a message for the person, and the field
/// it is about, or null when the profile can be kept.
pub const Check = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, profile: *const Profile) ?Refusal,
};
pub const Refusal = struct { field: Field, message: []const u8 };
pub const Field = enum { name, command, folder, font_size, variables };

extern "user32" fn DialogBoxIndirectParamW(hInstance: ?HINSTANCE, template: *const anyopaque, parent: ?HWND, proc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize, init: LPARAM) callconv(.winapi) isize;
extern "user32" fn EndDialog(hDlg: HWND, result: isize) callconv(.winapi) BOOL;
extern "user32" fn GetDlgItem(hDlg: HWND, id: i32) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn SetWindowTextW(hWnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(hWnd: HWND, text: [*]u16, max: i32) callconv(.winapi) i32;
extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) i32;
extern "user32" fn MessageBoxW(hwnd: ?HWND, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;

const IDOK: u16 = 1;
const IDCANCEL: u16 = 2;
const id_name: u16 = 120;
const id_command: u16 = 121;
const id_folder: u16 = 122;
const id_font_size: u16 = 123;
const id_elevated: u16 = 124;
const id_variables: u16 = 125;

const DWLP_USER: i32 = @sizeOf(usize) * 2;
const WM_INITDIALOG: UINT = 0x0110;
const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const BM_GETCHECK: UINT = 0x00F0;
const BM_SETCHECK: UINT = 0x00F1;

const State = struct {
    alloc: Allocator,
    profile: *Profile,
    title: [:0]const u16,
    check: Check,
};

/// Edit `profile` in a modal window over `owner`; OK runs `check` and keeps
/// the window open on a refusal. Returns whether OK was accepted.
pub fn edit(alloc: Allocator, owner: ?HWND, profile: *Profile, title: [:0]const u16, check: Check) Allocator.Error!bool {
    const template = try buildTemplate(alloc);
    defer alloc.free(template);
    var state: State = .{ .alloc = alloc, .profile = profile, .title = title, .check = check };
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
    const ES_AUTOVSCROLL: u32 = 0x40;
    const ES_MULTILINE: u32 = 0x4;
    const ES_WANTRETURN: u32 = 0x1000;
    const BS_AUTOCHECKBOX: u32 = 0x3;
    const BS_DEFPUSHBUTTON: u32 = 0x1;
    const button: u16 = 0x0080;
    const edit_atom: u16 = 0x0081;
    const static: u16 = 0x0082;

    const w: i16 = 320;
    const h: i16 = 236;
    const label_w: i16 = 86;
    const field_x: i16 = 7 + label_w + 4;
    const field_w: i16 = w - field_x - 7;
    const count: u16 = 4 * 2 + 1 + 1 + 3 + 2;
    try t.int(u32, 0x80000000 | 0x00C00000 | 0x00080000 | 0x80 | 0x40 | 0x800);
    try t.int(u32, 0);
    try t.int(u16, count);
    try t.int(i16, 0);
    try t.int(i16, 0);
    try t.int(i16, w);
    try t.int(i16, h);
    try t.int(u16, 0);
    try t.int(u16, 0);
    try t.wstr(L("Profile"));
    try t.int(u16, 9);
    try t.wstr(L("Segoe UI"));

    const text_style = child | WS_TABSTOP | WS_GROUP | WS_BORDER | ES_AUTOHSCROLL;
    var y: i16 = 9;
    const rows = [_]struct { label: []const u16, id: u16, width: i16 }{
        .{ .label = L("&Name"), .id = id_name, .width = field_w },
        .{ .label = L("&Command line"), .id = id_command, .width = field_w },
        .{ .label = L("Starting &folder"), .id = id_folder, .width = field_w },
        .{ .label = L("Font si&ze (zoom)"), .id = id_font_size, .width = 50 },
    };
    for (rows) |row| {
        try t.item(child, 7, y + 2, label_w, 9, 0xFFFF, static, row.label);
        try t.item(text_style, field_x, y, row.width, 12, row.id, edit_atom, L(""));
        y += 18;
    }
    try t.item(child, field_x + 56, 9 + 18 * 3 + 2, field_w - 56, 9, 0xFFFF, static, L("points; blank for the Settings size"));
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_AUTOCHECKBOX, field_x, y, field_w, 12, id_elevated, button, L("Open as &administrator (in its own window)"));
    y += 18;
    try t.item(child, 7, y + 2, label_w, 9, 0xFFFF, static, L("&Variables"));
    try t.item(child | WS_TABSTOP | WS_GROUP | WS_BORDER | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN, field_x, y, field_w, 60, id_variables, edit_atom, L(""));
    try t.item(child, field_x, y + 62, field_w, 9, 0xFFFF, static, L("One NAME=VALUE a line."));
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

/// `text` with every lone `\n` written as `\r\n`, for a multi-line EDIT.
fn setText(hwnd: HWND, id: u16, alloc: Allocator, text: []const u8) void {
    const control = GetDlgItem(hwnd, id) orelse return;
    var crlf: std.ArrayListUnmanaged(u8) = .empty;
    defer crlf.deinit(alloc);
    for (text, 0..) |byte, i| {
        if (byte == '\n' and (i == 0 or text[i - 1] != '\r')) crlf.append(alloc, '\r') catch return;
        crlf.append(alloc, byte) catch return;
    }
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, crlf.items) catch return;
    defer alloc.free(wide);
    _ = SetWindowTextW(control, wide.ptr);
}

fn readText(hwnd: HWND, id: u16, alloc: Allocator) ?[]u8 {
    const control = GetDlgItem(hwnd, id) orelse return null;
    const len: usize = @intCast(@max(0, GetWindowTextLengthW(control)));
    const buf = alloc.alloc(u16, len + 1) catch return null;
    defer alloc.free(buf);
    const got = GetWindowTextW(control, buf.ptr, @intCast(buf.len));
    const text = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..@intCast(@max(0, got))]) catch return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == text.len) return text;
    const copy = alloc.dupe(u8, trimmed) catch return null;
    alloc.free(text);
    return copy;
}

fn controlId(field: Field) u16 {
    return switch (field) {
        .name => id_name,
        .command => id_command,
        .folder => id_folder,
        .font_size => id_font_size,
        .variables => id_variables,
    };
}

fn dialogProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize {
    switch (msg) {
        WM_INITDIALOG => {
            _ = SetWindowLongPtrW(hwnd, DWLP_USER, lparam);
            const state = stateOf(hwnd) orelse return 1;
            const p = state.profile;
            const a = state.alloc;
            _ = SetWindowTextW(hwnd, state.title.ptr);
            setText(hwnd, id_name, a, p.name);
            setText(hwnd, id_command, a, p.command);
            setText(hwnd, id_folder, a, p.folder);
            setText(hwnd, id_font_size, a, p.font_size);
            setText(hwnd, id_variables, a, p.variables);
            if (GetDlgItem(hwnd, id_elevated)) |box| _ = SendMessageW(box, BM_SETCHECK, @intFromBool(p.elevated), 0);
            return 1;
        },
        WM_COMMAND => {
            const id: u16 = @truncate(wparam);
            switch (id) {
                IDOK => {
                    const state = stateOf(hwnd) orelse return 1;
                    const a = state.alloc;
                    const typed: Profile = .{
                        .name = readText(hwnd, id_name, a) orelse return 1,
                        .command = readText(hwnd, id_command, a) orelse return 1,
                        .folder = readText(hwnd, id_folder, a) orelse return 1,
                        .font_size = readText(hwnd, id_font_size, a) orelse return 1,
                        .elevated = if (GetDlgItem(hwnd, id_elevated)) |box| SendMessageW(box, BM_GETCHECK, 0, 0) == 1 else false,
                        .variables = readText(hwnd, id_variables, a) orelse return 1,
                    };
                    if (state.check.run(state.check.ctx, &typed)) |refusal| {
                        const message = std.unicode.utf8ToUtf16LeAllocZ(a, refusal.message) catch return 1;
                        _ = MessageBoxW(hwnd, message.ptr, L("Profile"), 0x30);
                        if (GetDlgItem(hwnd, controlId(refusal.field))) |control| _ = SetFocus(control);
                        return 1;
                    }
                    state.profile.* = typed;
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

/// The `NAME=VALUE` lines of the Variables field: each trimmed, empty lines
/// skipped. A line without `=` is returned with an empty name, for the
/// caller to refuse.
pub const VariableIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn init(text: []const u8) VariableIterator {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    pub fn next(self: *VariableIterator) ?struct { name: []const u8, value: []const u8 } {
        while (self.lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .{ .name = "", .value = line };
            return .{ .name = std.mem.trim(u8, line[0..eq], " \t"), .value = std.mem.trim(u8, line[eq + 1 ..], " \t") };
        }
        return null;
    }
};

test "profile dialog: the template is DWORD aligned and counts its items" {
    const template = try buildTemplate(std.testing.allocator);
    defer std.testing.allocator.free(template);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(template.ptr) % 4);
    try std.testing.expectEqual(@as(u16, 15), std.mem.readInt(u16, template[8..10], .little));
}

test "profile dialog: variables are one NAME=VALUE a line" {
    var it = VariableIterator.init("A=1\r\n\r\n  B = two words \nbroken\n");
    const a = it.next().?;
    try std.testing.expectEqualStrings("A", a.name);
    try std.testing.expectEqualStrings("1", a.value);
    const b = it.next().?;
    try std.testing.expectEqualStrings("B", b.name);
    try std.testing.expectEqualStrings("two words", b.value);
    const c = it.next().?;
    try std.testing.expectEqualStrings("", c.name);
    try std.testing.expect(it.next() == null);
}
