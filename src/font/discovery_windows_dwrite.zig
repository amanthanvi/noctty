//! Ask Windows which installed font it would use for a codepoint.
//!
//! Font discovery on Windows scans font files for FreeType, so when the
//! primary fonts lack a codepoint, every installed face that covers it ties
//! on style and weight, and the tie used to go to scan order. DirectWrite's
//! system font fallback (`IDWriteFontFallback::MapCharacters`) already knows
//! which font Windows uses for each script in the user's locale; this module
//! asks it and returns the answer as a local file path plus face index, so
//! the scanner can rank that record first.
//!
//! DirectWrite is loaded at runtime (like the shell chrome does), so there is
//! no link-time dependency. Every failure is reported as "no answer" and the
//! caller keeps its own ordering. Interface layouts and GUIDs are taken from
//! the Windows SDK headers (dwrite.h, dwrite_1.h, dwrite_2.h).

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.discovery);

/// A face DirectWrite chose, as the scanner identifies faces.
pub const Mapped = struct {
    /// UTF-8, owned by the caller's allocator.
    path: [:0]const u8,
    face_index: i32,

    pub fn deinit(self: *Mapped, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = undefined;
    }
};

/// DirectWrite's system font fallback, created once and reused. Not
/// thread-safe on its own; the scanner calls it under its mutex.
pub const SystemFallback = struct {
    module: ?*anyopaque = null,
    factory: ?*IDWriteFactory2 = null,
    fallback: ?*IDWriteFontFallback = null,
    /// Null-terminated user locale, e.g. "ja-JP". DirectWrite picks
    /// language-appropriate fonts from it, most visibly for CJK text.
    locale: [locale_name_max]u16 = [_]u16{0} ** locale_name_max,
    /// Set after the first attempt, successful or not, so a machine
    /// without DirectWrite fallback is not retried on every codepoint.
    tried: bool = false,

    pub fn deinit(self: *SystemFallback) void {
        if (self.fallback) |fallback| _ = fallback.vtbl.Release(fallback);
        if (self.factory) |factory| _ = factory.vtbl.Release(factory);
        if (self.module) |module| _ = k32.FreeLibrary(module);
        self.* = .{};
    }

    fn ensure(self: *SystemFallback) bool {
        if (self.fallback != null) return true;
        if (self.tried) return false;
        self.tried = true;

        const module = k32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dwrite.dll")) orelse {
            log.warn("dwrite.dll unavailable; system font fallback disabled", .{});
            return false;
        };
        self.module = module;
        const create = k32.GetProcAddress(module, "DWriteCreateFactory") orelse return false;
        const create_factory: *const DWriteCreateFactoryFn = @ptrCast(create);

        var factory: ?*anyopaque = null;
        if (create_factory(dwrite_factory_type_shared, &IID_IDWriteFactory2, &factory) < 0) {
            // IDWriteFactory2 needs Windows 8.1 or later.
            log.warn("IDWriteFactory2 unavailable; system font fallback disabled", .{});
            return false;
        }
        const factory2: *IDWriteFactory2 = @ptrCast(@alignCast(factory orelse return false));
        self.factory = factory2;

        var fallback: ?*IDWriteFontFallback = null;
        if (factory2.vtbl.GetSystemFontFallback(factory2, &fallback) < 0) return false;
        self.fallback = fallback orelse return false;

        if (k32.GetUserDefaultLocaleName(&self.locale, locale_name_max) == 0) {
            const fallback_locale = std.unicode.utf8ToUtf16LeStringLiteral("en-US");
            @memcpy(self.locale[0..fallback_locale.len], fallback_locale);
            self.locale[fallback_locale.len] = 0;
        }
        return true;
    }

    /// The local font file DirectWrite would use for `codepoint` in the
    /// requested style, or null when it has no answer (no fallback API, no
    /// font covers the codepoint, or the font is not a local file).
    pub fn map(
        self: *SystemFallback,
        alloc: Allocator,
        codepoint: u21,
        bold: bool,
        italic: bool,
    ) !?Mapped {
        if (!self.ensure()) return null;
        const fallback = self.fallback.?;

        var source: TextSource = .{ .locale = &self.locale };
        source.len = @intCast(std.unicode.utf8Encode(codepoint, &source.utf8) catch return null);
        source.len = @intCast(std.unicode.utf8ToUtf16Le(&source.text, source.utf8[0..source.len]) catch return null);

        var mapped_length: u32 = 0;
        var font: ?*IDWriteFont = null;
        var scale: f32 = 1.0;
        if (fallback.vtbl.MapCharacters(
            fallback,
            &source.iface,
            0,
            source.len,
            null,
            null,
            if (bold) dwrite_font_weight_bold else dwrite_font_weight_normal,
            if (italic) dwrite_font_style_italic else dwrite_font_style_normal,
            dwrite_font_stretch_normal,
            &mapped_length,
            &font,
            &scale,
        ) < 0) return null;
        const mapped_font = font orelse return null;
        defer _ = mapped_font.vtbl.Release(mapped_font);
        if (mapped_length == 0) return null;

        return try localFileOf(alloc, mapped_font);
    }
};

fn localFileOf(alloc: Allocator, font: *IDWriteFont) !?Mapped {
    var face: ?*IDWriteFontFace = null;
    if (font.vtbl.CreateFontFace(font, &face) < 0) return null;
    const font_face = face orelse return null;
    defer _ = font_face.vtbl.Release(font_face);

    // A face made of several files is not something the scanner indexes.
    var file_count: u32 = 0;
    if (font_face.vtbl.GetFiles(font_face, &file_count, null) < 0 or file_count != 1) return null;
    var file: ?*IDWriteFontFile = null;
    if (font_face.vtbl.GetFiles(font_face, &file_count, @ptrCast(&file)) < 0) return null;
    const font_file = file orelse return null;
    defer _ = font_file.vtbl.Release(font_file);

    var key: ?*const anyopaque = null;
    var key_size: u32 = 0;
    if (font_file.vtbl.GetReferenceKey(font_file, &key, &key_size) < 0) return null;

    var loader: ?*IDWriteFontFileLoader = null;
    if (font_file.vtbl.GetLoader(font_file, &loader) < 0) return null;
    const file_loader = loader orelse return null;
    defer _ = file_loader.vtbl.Release(file_loader);

    // Only fonts that live in a local file can be handed to FreeType;
    // anything else (in-memory, downloadable) is left to the scanner.
    var local: ?*anyopaque = null;
    if (file_loader.vtbl.QueryInterface(file_loader, &IID_IDWriteLocalFontFileLoader, &local) < 0) return null;
    const local_loader: *IDWriteLocalFontFileLoader = @ptrCast(@alignCast(local orelse return null));
    defer _ = local_loader.vtbl.Release(local_loader);

    var path_len: u32 = 0;
    if (local_loader.vtbl.GetFilePathLengthFromKey(local_loader, key, key_size, &path_len) < 0) return null;
    const wide = try alloc.alloc(u16, @as(usize, path_len) + 1);
    defer alloc.free(wide);
    if (local_loader.vtbl.GetFilePathFromKey(local_loader, key, key_size, wide.ptr, path_len + 1) < 0) return null;

    const path = std.unicode.utf16LeToUtf8AllocZ(alloc, wide[0..path_len]) catch return null;
    return .{
        .path = path,
        .face_index = @intCast(font_face.vtbl.GetIndex(font_face)),
    };
}

/// Whether a scanned font file is the one DirectWrite named. Paths from
/// the two sources differ in case and possibly in separator.
pub fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '/') '\\' else std.ascii.toLower(x);
        const ny = if (y == '/') '\\' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

//-----------------------------------------------------------------------
// IDWriteTextAnalysisSource: the text DirectWrite maps. It holds one
// codepoint (one or two UTF-16 units) and lives on the caller's stack for
// the duration of a single MapCharacters call, so reference counting is a
// no-op.

const TextSource = struct {
    iface: IDWriteTextAnalysisSource = .{ .vtbl = &text_source_vtbl },
    utf8: [4]u8 = undefined,
    text: [2]u16 = undefined,
    len: u32 = 0,
    locale: *const [locale_name_max]u16,

    fn from(iface: *IDWriteTextAnalysisSource) *TextSource {
        return @fieldParentPtr("iface", iface);
    }

    fn queryInterface(iface: *IDWriteTextAnalysisSource, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (iid.eql(&IID_IUnknown) or iid.eql(&IID_IDWriteTextAnalysisSource)) {
            out.* = iface;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(_: *IDWriteTextAnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn release(_: *IDWriteTextAnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn getTextAtPosition(iface: *IDWriteTextAnalysisSource, position: u32, text: *?[*]const u16, length: *u32) callconv(.winapi) HRESULT {
        const self = from(iface);
        if (position >= self.len) {
            text.* = null;
            length.* = 0;
        } else {
            text.* = self.text[position..].ptr;
            length.* = self.len - position;
        }
        return S_OK;
    }

    fn getTextBeforePosition(iface: *IDWriteTextAnalysisSource, position: u32, text: *?[*]const u16, length: *u32) callconv(.winapi) HRESULT {
        const self = from(iface);
        if (position == 0 or position > self.len) {
            text.* = null;
            length.* = 0;
        } else {
            text.* = &self.text;
            length.* = position;
        }
        return S_OK;
    }

    fn getParagraphReadingDirection(_: *IDWriteTextAnalysisSource) callconv(.winapi) u32 {
        return dwrite_reading_direction_left_to_right;
    }

    fn getLocaleName(iface: *IDWriteTextAnalysisSource, position: u32, length: *u32, locale: *?[*:0]const u16) callconv(.winapi) HRESULT {
        const self = from(iface);
        length.* = self.len -| position;
        locale.* = @ptrCast(self.locale);
        return S_OK;
    }

    fn getNumberSubstitution(iface: *IDWriteTextAnalysisSource, position: u32, length: *u32, substitution: *?*anyopaque) callconv(.winapi) HRESULT {
        const self = from(iface);
        length.* = self.len -| position;
        substitution.* = null;
        return S_OK;
    }
};

const text_source_vtbl: IDWriteTextAnalysisSourceVtbl = .{
    .QueryInterface = TextSource.queryInterface,
    .AddRef = TextSource.addRef,
    .Release = TextSource.release,
    .GetTextAtPosition = TextSource.getTextAtPosition,
    .GetTextBeforePosition = TextSource.getTextBeforePosition,
    .GetParagraphReadingDirection = TextSource.getParagraphReadingDirection,
    .GetLocaleName = TextSource.getLocaleName,
    .GetNumberSubstitution = TextSource.getNumberSubstitution,
};

//-----------------------------------------------------------------------
// Win32 / COM declarations.

const HRESULT = i32;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

const locale_name_max = 85; // LOCALE_NAME_MAX_LENGTH
const dwrite_factory_type_shared: u32 = 0;
const dwrite_font_weight_normal: u32 = 400;
const dwrite_font_weight_bold: u32 = 700;
const dwrite_font_style_normal: u32 = 0;
const dwrite_font_style_italic: u32 = 2;
const dwrite_font_stretch_normal: u32 = 5;
const dwrite_reading_direction_left_to_right: u32 = 0;

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    fn eql(self: *const GUID, other: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(self), std.mem.asBytes(other));
    }
};

const IID_IUnknown: GUID = .{ .data1 = 0x00000000, .data2 = 0x0000, .data3 = 0x0000, .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
// dwrite_2.h: 0439fc60-ca44-4994-8dee-3a9af7b732ec
const IID_IDWriteFactory2: GUID = .{ .data1 = 0x0439fc60, .data2 = 0xca44, .data3 = 0x4994, .data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec } };
// dwrite.h: 688e1a58-5094-47c8-adc8-fbcea60ae92b
const IID_IDWriteTextAnalysisSource: GUID = .{ .data1 = 0x688e1a58, .data2 = 0x5094, .data3 = 0x47c8, .data4 = .{ 0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b } };
// dwrite.h: b2d9f3ec-c9fe-4a11-a2ec-d86208f7c0a2
const IID_IDWriteLocalFontFileLoader: GUID = .{ .data1 = 0xb2d9f3ec, .data2 = 0xc9fe, .data3 = 0x4a11, .data4 = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 } };

const DWriteCreateFactoryFn = fn (factory_type: u32, iid: *const GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT;

/// Unused slots are placeholders; only their count matters.
const Slot = *const anyopaque;

// IDWriteFactory (21 methods) + IDWriteFactory1 (2) + IDWriteFactory2.
const IDWriteFactory2 = extern struct { vtbl: *const IDWriteFactory2Vtbl };
const IDWriteFactory2Vtbl = extern struct {
    QueryInterface: Slot,
    AddRef: Slot,
    Release: *const fn (*IDWriteFactory2) callconv(.winapi) u32,
    factory_slots: [21]Slot,
    factory1_slots: [2]Slot,
    GetSystemFontFallback: *const fn (*IDWriteFactory2, *?*IDWriteFontFallback) callconv(.winapi) HRESULT,
};

const IDWriteFontFallback = extern struct { vtbl: *const IDWriteFontFallbackVtbl };
const IDWriteFontFallbackVtbl = extern struct {
    QueryInterface: Slot,
    AddRef: Slot,
    Release: *const fn (*IDWriteFontFallback) callconv(.winapi) u32,
    MapCharacters: *const fn (
        *IDWriteFontFallback,
        *IDWriteTextAnalysisSource,
        text_position: u32,
        text_length: u32,
        base_font_collection: ?*anyopaque,
        base_family_name: ?[*:0]const u16,
        base_weight: u32,
        base_style: u32,
        base_stretch: u32,
        mapped_length: *u32,
        mapped_font: *?*IDWriteFont,
        scale: *f32,
    ) callconv(.winapi) HRESULT,
};

const IDWriteTextAnalysisSource = extern struct { vtbl: *const IDWriteTextAnalysisSourceVtbl };
const IDWriteTextAnalysisSourceVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteTextAnalysisSource, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
    Release: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
    GetTextAtPosition: *const fn (*IDWriteTextAnalysisSource, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
    GetTextBeforePosition: *const fn (*IDWriteTextAnalysisSource, u32, *?[*]const u16, *u32) callconv(.winapi) HRESULT,
    GetParagraphReadingDirection: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
    GetLocaleName: *const fn (*IDWriteTextAnalysisSource, u32, *u32, *?[*:0]const u16) callconv(.winapi) HRESULT,
    GetNumberSubstitution: *const fn (*IDWriteTextAnalysisSource, u32, *u32, *?*anyopaque) callconv(.winapi) HRESULT,
};

// IDWriteFont: GetFontFamily, GetWeight, GetStretch, GetStyle,
// IsSymbolFont, GetFaceNames, GetInformationalStrings, GetSimulations,
// GetMetrics, HasCharacter, then CreateFontFace.
const IDWriteFont = extern struct { vtbl: *const IDWriteFontVtbl };
const IDWriteFontVtbl = extern struct {
    QueryInterface: Slot,
    AddRef: Slot,
    Release: *const fn (*IDWriteFont) callconv(.winapi) u32,
    font_slots: [10]Slot,
    CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
};

// IDWriteFontFace: GetType, then GetFiles, then GetIndex.
const IDWriteFontFace = extern struct { vtbl: *const IDWriteFontFaceVtbl };
const IDWriteFontFaceVtbl = extern struct {
    QueryInterface: Slot,
    AddRef: Slot,
    Release: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
    GetType: Slot,
    GetFiles: *const fn (*IDWriteFontFace, *u32, ?[*]?*IDWriteFontFile) callconv(.winapi) HRESULT,
    GetIndex: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
};

const IDWriteFontFile = extern struct { vtbl: *const IDWriteFontFileVtbl };
const IDWriteFontFileVtbl = extern struct {
    QueryInterface: Slot,
    AddRef: Slot,
    Release: *const fn (*IDWriteFontFile) callconv(.winapi) u32,
    GetReferenceKey: *const fn (*IDWriteFontFile, *?*const anyopaque, *u32) callconv(.winapi) HRESULT,
    GetLoader: *const fn (*IDWriteFontFile, *?*IDWriteFontFileLoader) callconv(.winapi) HRESULT,
};

const IDWriteFontFileLoader = extern struct { vtbl: *const IDWriteFontFileLoaderVtbl };
const IDWriteFontFileLoaderVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontFileLoader, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: Slot,
    Release: *const fn (*IDWriteFontFileLoader) callconv(.winapi) u32,
};

// IDWriteLocalFontFileLoader: IDWriteFontFileLoader's CreateStreamFromKey,
// then GetFilePathLengthFromKey and GetFilePathFromKey.
const IDWriteLocalFontFileLoader = extern struct { vtbl: *const IDWriteLocalFontFileLoaderVtbl };
const IDWriteLocalFontFileLoaderVtbl = extern struct {
    QueryInterface: Slot,
    AddRef: Slot,
    Release: *const fn (*IDWriteLocalFontFileLoader) callconv(.winapi) u32,
    CreateStreamFromKey: Slot,
    GetFilePathLengthFromKey: *const fn (*IDWriteLocalFontFileLoader, ?*const anyopaque, u32, *u32) callconv(.winapi) HRESULT,
    GetFilePathFromKey: *const fn (*IDWriteLocalFontFileLoader, ?*const anyopaque, u32, [*]u16, u32) callconv(.winapi) HRESULT,
};

const k32 = struct {
    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn GetUserDefaultLocaleName(name: [*]u16, len: i32) callconv(.winapi) i32;
};

//-----------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

test "windowsDwriteSamePathIgnoresCaseAndSeparator" {
    try testing.expect(samePath("C:\\Windows\\Fonts\\arial.ttf", "c:/WINDOWS/FONTS/ARIAL.TTF"));
    try testing.expect(!samePath("C:\\Windows\\Fonts\\arial.ttf", "C:\\Windows\\Fonts\\arialbd.ttf"));
    try testing.expect(!samePath("C:\\a.ttf", "C:\\a.ttc"));
}

test "windowsDwriteGuidLayoutMatchesSdk" {
    // A transposed byte silently makes QueryInterface fail, and DirectWrite
    // would then look unavailable. Pin the byte layout.
    try testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    const bytes = std.mem.asBytes(&IID_IDWriteLocalFontFileLoader);
    try testing.expectEqualSlices(u8, &.{ 0xec, 0xf3, 0xd9, 0xb2, 0xfe, 0xc9, 0x11, 0x4a, 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 }, bytes);
}

test "windowsDwriteVtableSlotsMatchSdk" {
    // Slot positions counted from the SDK headers; a wrong count calls the
    // wrong method.
    const ptr = @sizeOf(usize);
    try testing.expectEqual(26 * ptr, @offsetOf(IDWriteFactory2Vtbl, "GetSystemFontFallback"));
    try testing.expectEqual(3 * ptr, @offsetOf(IDWriteFontFallbackVtbl, "MapCharacters"));
    try testing.expectEqual(13 * ptr, @offsetOf(IDWriteFontVtbl, "CreateFontFace"));
    try testing.expectEqual(4 * ptr, @offsetOf(IDWriteFontFaceVtbl, "GetFiles"));
    try testing.expectEqual(5 * ptr, @offsetOf(IDWriteFontFaceVtbl, "GetIndex"));
    try testing.expectEqual(4 * ptr, @offsetOf(IDWriteFontFileVtbl, "GetLoader"));
    try testing.expectEqual(5 * ptr, @offsetOf(IDWriteLocalFontFileLoaderVtbl, "GetFilePathFromKey"));
    try testing.expectEqual(7 * ptr, @offsetOf(IDWriteTextAnalysisSourceVtbl, "GetNumberSubstitution"));
}

test "windowsDwriteSystemFallbackMapsToALocalFontFile" {
    // Asserts only what holds on any Windows install: DirectWrite names an
    // existing local file for a Latin letter and for a CJK ideograph. Which
    // font that is depends on the machine and locale, so it is not checked.
    if (comptime builtin.os.tag == .windows) {
        var fallback: SystemFallback = .{};
        defer fallback.deinit();
        for ([_]u21{ 'A', 0x4E2D }) |codepoint| {
            var mapped = (try fallback.map(testing.allocator, codepoint, false, false)) orelse
                return error.TestUnexpectedResult;
            defer mapped.deinit(testing.allocator);
            try testing.expect(mapped.path.len > 0);
            try testing.expect(mapped.face_index >= 0);
            const file = try std.fs.openFileAbsolute(mapped.path, .{});
            file.close();
        }
    } else return error.SkipZigTest;
}
