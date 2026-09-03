const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const freetype = @import("freetype");
const Collection = @import("main.zig").Collection;
const DeferredFace = @import("main.zig").DeferredFace;
pub const Descriptor = @import("descriptor.zig").Descriptor;
const Variation = @import("variation.zig").Variation;

const log = std.log.scoped(.discovery);

pub const Discover = Windows;

/// Font discovery for Windows. Fonts are enumerated from three sources:
///
///   1. The system font directory (%WINDIR%\Fonts)
///   2. The per-user font directory (%LOCALAPPDATA%\Microsoft\Windows\Fonts),
///      which is where Windows 10 1809+ installs fonts by default
///   3. The per-user font registry key
///      (HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts), which
///      catches fonts registered at arbitrary paths (e.g. by font managers)
///
/// Each font file is inspected with FreeType for its family/style names.
/// Codepoint coverage (charset) is computed lazily per face the first time
/// a query needs it, never during the scan itself.
///
/// The record set can be refreshed at runtime (see `refresh`) so fonts
/// installed while the app is running are picked up on config reload
/// without a restart.
pub const Windows = struct {
    alloc: Allocator,
    system_dir: ?[:0]const u8,
    user_dir: ?[:0]const u8,
    records: []Record,

    /// Guards `records` (including the lazily-computed charsets inside
    /// them). Discovery can be called concurrently from multiple renderer
    /// threads via codepoint-fallback resolution while a refresh swaps
    /// the record set.
    mutex: std.Thread.Mutex,

    /// Snapshot of the font sources at the time of the last successful
    /// scan; used by `refresh` to skip rescanning when nothing changed.
    /// Null means we have never scanned.
    state: ?ScanState,

    const Record = struct {
        path: [:0]const u8,
        face_index: i32,
        family_name: [:0]const u8,
        style_name: [:0]const u8,
        full_name: [:0]const u8,
        /// Typographic family (OpenType name ID 16), when present and
        /// distinct information from the legacy family. This is the name
        /// the Windows Fonts UI shows for weight-split families, so users
        /// copy it into their config.
        typographic_family: ?[:0]const u8,
        /// Typographic subfamily (OpenType name ID 17), when present. For
        /// weight-split families the legacy subfamily flattens to
        /// "Regular" and this carries the real style ("Light", "SemiBold").
        typographic_style: ?[:0]const u8,
        /// OS/2 usWeightClass (100-1000), or 0 when the face has no usable
        /// OS/2 table. Nerd Fonts and other weight-split families rely on
        /// this to distinguish faces that share a style name.
        weight: u16,
        monospace: bool,
        bold: bool,
        italic: bool,
        color: bool,
        variable: bool,
        has_codepoint: bool,
        /// Sorted codepoint coverage. Computed lazily on first use under
        /// the discovery mutex; null means not yet computed.
        charset: ?[]const u32,

        fn deinit(self: *Record, alloc: Allocator) void {
            if (self.charset) |charset| alloc.free(charset);
            if (self.typographic_family) |name| alloc.free(name);
            if (self.typographic_style) |name| alloc.free(name);
            alloc.free(self.path);
            alloc.free(self.family_name);
            alloc.free(self.style_name);
            alloc.free(self.full_name);
            self.* = undefined;
        }
    };

    pub fn init() Windows {
        const alloc = std.heap.page_allocator;
        return .{
            .alloc = alloc,
            .system_dir = systemFontsDir(alloc) catch |err| dir: {
                log.warn("windows system fonts dir unavailable err={}", .{err});
                break :dir null;
            },
            .user_dir = userFontsDir(alloc) catch null,
            .records = alloc.alloc(Record, 0) catch unreachable,
            .mutex = .{},
            .state = null,
        };
    }

    pub fn deinit(self: *Windows) void {
        const alloc = self.alloc;
        for (self.records) |*record| record.deinit(alloc);
        alloc.free(self.records);
        if (self.system_dir) |dir| alloc.free(dir);
        if (self.user_dir) |dir| alloc.free(dir);
        self.* = undefined;
    }

    /// Rescan the font sources if they changed since the last scan (or if
    /// we never scanned). Cheap when nothing changed: two directory stats
    /// and one registry query. Serialized by the caller (SharedGridSet
    /// holds its own lock across collection creation); concurrent
    /// `discover` calls are safe because the record swap happens under
    /// our mutex and iterators hold deep copies.
    pub fn refresh(self: *Windows) void {
        const state = self.scanState();
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state) |prev| if (prev.eql(state)) return;
        }

        const records = self.scanAll() catch |err| {
            log.warn("windows font discovery scan failed err={}", .{err});
            return;
        };
        if (records.len == 0) {
            log.warn("windows font discovery found no fonts", .{});
        } else {
            log.info("windows font discovery found {d} font faces", .{records.len});
        }

        self.mutex.lock();
        const old = self.records;
        self.records = records;
        self.state = state;
        self.mutex.unlock();

        for (old) |*record| record.deinit(self.alloc);
        self.alloc.free(old);
    }

    pub fn discover(
        self: *Windows,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        // Some consumers (e.g. the +list-fonts CLI action) use
        // init()+discover() directly and never call refresh(); make the
        // first scan self-healing so they still see fonts. Concurrent
        // first calls can at worst scan twice; the extra result is freed.
        if (!self.hasScanned()) self.refresh();

        const filtered = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk try self.filterRecordsLocked(alloc, desc);
        };
        errdefer {
            for (filtered) |*record| record.deinit(alloc);
            alloc.free(filtered);
        }

        // Stable so that faces the scan saw in a fixed order keep that
        // order when they score identically.
        std.mem.sort(Record, filtered, desc, struct {
            fn lessThan(desc_inner: Descriptor, lhs: Record, rhs: Record) bool {
                return score(desc_inner, lhs) > score(desc_inner, rhs);
            }
        }.lessThan);

        return .{
            .alloc = alloc,
            .records = filtered,
            .variations = desc.variations,
            .i = 0,
        };
    }

    fn hasScanned(self: *Windows) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state != null;
    }

    pub fn discoverFallback(
        self: *Windows,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        /// Deep copies of the matching records (owned by `alloc`), so the
        /// iterator stays valid even if a concurrent refresh replaces the
        /// discovery's record set.
        records: []Record,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            // Records before `i` were consumed by next(), which transferred
            // their allocations into the returned faces.
            for (self.records[self.i..]) |*record| record.deinit(self.alloc);
            self.alloc.free(self.records);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.records.len) return null;
            const record = &self.records[self.i];

            // The only fallible step happens before any ownership moves,
            // so a failure here leaks nothing and leaves the record
            // available for a retry.
            const variations = try self.alloc.dupe(Variation, self.variations);

            // Transfer the record's allocations into the face (same
            // allocator, no second copy). The typographic subfamily has no
            // destination field, so it is released here.
            if (record.typographic_style) |name| self.alloc.free(name);
            const face: DeferredFace = .{
                .win = .{
                    .alloc = self.alloc,
                    .path = record.path,
                    .face_index = record.face_index,
                    .family_name = record.family_name,
                    .style_name = record.style_name,
                    .full_name = record.full_name,
                    .typographic_family = record.typographic_family,
                    .variations = variations,
                    .color = record.color,
                    // Filtered records always carry a materialized charset
                    // (see filterRecordsLocked).
                    .charset = record.charset.?,
                },
            };
            record.* = undefined;
            self.i += 1;
            return face;
        }
    };

    //-------------------------------------------------------------------
    // Font source enumeration

    fn systemFontsDir(alloc: Allocator) ![:0]const u8 {
        const base = envBase: {
            const windir = envDir(alloc, "WINDIR") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => envDir(alloc, "SystemRoot") catch |inner| switch (inner) {
                    error.EnvironmentVariableNotFound => break :envBase try alloc.dupe(u8, "C:\\Windows"),
                    else => return inner,
                },
                else => return err,
            };
            break :envBase windir;
        };
        defer alloc.free(base);
        const path = try std.fmt.allocPrint(alloc, "{s}\\Fonts", .{base});
        defer alloc.free(path);
        return try alloc.dupeZ(u8, path);
    }

    fn userFontsDir(alloc: Allocator) ![:0]const u8 {
        const base = try envDir(alloc, "LOCALAPPDATA");
        defer alloc.free(base);
        const path = try std.fmt.allocPrint(alloc, "{s}\\Microsoft\\Windows\\Fonts", .{base});
        defer alloc.free(path);
        return try alloc.dupeZ(u8, path);
    }

    fn envDir(alloc: Allocator, key: []const u8) ![]u8 {
        return try std.process.getEnvVarOwned(alloc, key);
    }

    /// Scan all font sources and return the records. Individual files and
    /// faces that fail to load are skipped; only allocation failure aborts
    /// the scan.
    fn scanAll(self: *Windows) ![]Record {
        const alloc = self.alloc;

        var paths: std.ArrayListUnmanaged([:0]const u8) = .{};
        defer {
            for (paths.items) |path| alloc.free(path);
            paths.deinit(alloc);
        }
        var seen: std.StringHashMapUnmanaged(void) = .{};
        defer {
            var it = seen.keyIterator();
            while (it.next()) |key| alloc.free(key.*);
            seen.deinit(alloc);
        }

        if (self.system_dir) |dir| try collectDirFontPaths(alloc, dir, &paths, &seen);
        if (self.user_dir) |dir| try collectDirFontPaths(alloc, dir, &paths, &seen);
        try collectRegistryFontPaths(alloc, self.system_dir, &paths, &seen);

        var lib = freetype.Library.init() catch |err| {
            log.warn("windows font discovery freetype init failed err={}", .{err});
            return try alloc.alloc(Record, 0);
        };
        defer lib.deinit();

        var records: std.ArrayListUnmanaged(Record) = .{};
        errdefer {
            for (records.items) |*record| record.deinit(alloc);
            records.deinit(alloc);
        }

        for (paths.items) |path| try scanPath(alloc, lib, path, &records);

        return try records.toOwnedSlice(alloc);
    }

    /// Collect supported font file paths from a directory. Filesystem
    /// errors are logged and skipped; only allocation failure propagates.
    fn collectDirFontPaths(
        alloc: Allocator,
        dir_path: [:0]const u8,
        paths: *std.ArrayListUnmanaged([:0]const u8),
        seen: *std.StringHashMapUnmanaged(void),
    ) error{OutOfMemory}!void {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
            log.warn("windows font discovery cannot open dir={s} err={}", .{ dir_path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (true) {
            const entry = iter.next() catch |err| {
                log.warn("windows font discovery dir iteration failed dir={s} err={}", .{ dir_path, err });
                break;
            } orelse break;
            if (entry.kind != .file) continue;
            if (!supportedFontFile(entry.name)) continue;

            const joined = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ dir_path, entry.name });
            defer alloc.free(joined);
            try addUniquePath(alloc, paths, seen, joined);
        }
    }

    /// Collect font file paths registered under the per-user font registry
    /// key. This catches fonts registered outside the standard directories
    /// (e.g. activated by font managers). Registry errors are non-fatal.
    fn collectRegistryFontPaths(
        alloc: Allocator,
        system_dir: ?[:0]const u8,
        paths: *std.ArrayListUnmanaged([:0]const u8),
        seen: *std.StringHashMapUnmanaged(void),
    ) error{OutOfMemory}!void {
        var hkey: winreg.HKEY = 0;
        if (winreg.RegOpenKeyExW(
            winreg.HKEY_CURRENT_USER,
            fonts_subkey,
            0,
            winreg.KEY_READ,
            &hkey,
        ) != winreg.ERROR_SUCCESS) return;
        defer _ = winreg.RegCloseKey(hkey);

        var index: u32 = 0;
        while (true) : (index += 1) {
            var name_buf: [260]u16 = undefined;
            var name_len: u32 = name_buf.len;
            var value_type: u32 = 0;
            var data_buf: [1040]u16 = undefined;
            var data_len: u32 = @sizeOf(@TypeOf(data_buf));

            const rc = winreg.RegEnumValueW(
                hkey,
                index,
                &name_buf,
                &name_len,
                null,
                &value_type,
                @ptrCast(&data_buf),
                &data_len,
            );
            if (rc == winreg.ERROR_NO_MORE_ITEMS) break;
            // Oversized name/data: not a font path we care about, skip it.
            if (rc == winreg.ERROR_MORE_DATA) continue;
            if (rc != winreg.ERROR_SUCCESS) break;
            if (value_type != winreg.REG_SZ and value_type != winreg.REG_EXPAND_SZ) continue;

            const raw: []const u16 = data_buf[0 .. data_len / 2];
            const value_utf16 = std.mem.sliceTo(raw, 0);
            if (value_utf16.len == 0) continue;

            var expanded_buf: [1040]u16 = undefined;
            const final_utf16: []const u16 = if (value_type == winreg.REG_EXPAND_SZ) expand: {
                var src_buf: [1041]u16 = undefined;
                if (value_utf16.len >= src_buf.len) continue;
                @memcpy(src_buf[0..value_utf16.len], value_utf16);
                src_buf[value_utf16.len] = 0;
                const n = winreg.ExpandEnvironmentStringsW(
                    @ptrCast(&src_buf),
                    &expanded_buf,
                    expanded_buf.len,
                );
                // n includes the terminating NUL on success.
                if (n == 0 or n > expanded_buf.len) continue;
                break :expand expanded_buf[0 .. n - 1];
            } else value_utf16;

            const value_utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, final_utf16) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            defer alloc.free(value_utf8);

            const resolved = (try resolveRegistryFontPath(alloc, value_utf8, system_dir)) orelse continue;
            defer alloc.free(resolved);
            try addUniquePath(alloc, paths, seen, resolved);
        }
    }

    /// Resolve a font registry value to an absolute path, or null if it
    /// isn't a usable font file. Registry font values are either absolute
    /// paths (per-user installs, font managers) or bare file names that
    /// are relative to the system fonts directory.
    fn resolveRegistryFontPath(
        alloc: Allocator,
        value: []const u8,
        system_dir: ?[]const u8,
    ) error{OutOfMemory}!?[]u8 {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len == 0) return null;
        if (!supportedFontFile(trimmed)) return null;
        if (std.fs.path.isAbsoluteWindows(trimmed)) return try alloc.dupe(u8, trimmed);
        const dir = system_dir orelse return null;
        return try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ dir, trimmed });
    }

    /// Append the path if it hasn't been seen yet (case-insensitive).
    fn addUniquePath(
        alloc: Allocator,
        paths: *std.ArrayListUnmanaged([:0]const u8),
        seen: *std.StringHashMapUnmanaged(void),
        path: []const u8,
    ) error{OutOfMemory}!void {
        const key = try std.ascii.allocLowerString(alloc, path);
        const gop = try seen.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            return;
        }
        // The key is now owned by the map; the caller's defer frees it.
        const owned = try alloc.dupeZ(u8, path);
        errdefer alloc.free(owned);
        try paths.append(alloc, owned);
    }

    /// Inspect every face of a font file. Per-file and per-face failures
    /// are logged and skipped; only allocation failure propagates.
    fn scanPath(
        alloc: Allocator,
        lib: freetype.Library,
        path: [:0]const u8,
        records: *std.ArrayListUnmanaged(Record),
    ) error{OutOfMemory}!void {
        var face0 = lib.initFace(path, 0) catch |err| {
            log.debug("windows font discovery skipped path={s} err={}", .{ path, err });
            return;
        };
        defer face0.deinit();

        const num_faces: usize = @intCast(@max(face0.handle.*.num_faces, 1));
        for (0..num_faces) |i| {
            const face_index: i32 = @intCast(i);
            const face = if (i == 0) face0 else lib.initFace(path, face_index) catch |err| {
                log.debug("windows font discovery face skipped path={s} index={} err={}", .{ path, face_index, err });
                continue;
            };
            defer if (i != 0) face.deinit();

            var record = try inspectFace(alloc, path, face, face_index);
            errdefer record.deinit(alloc);
            try records.append(alloc, record);
        }
    }

    fn inspectFace(
        alloc: Allocator,
        path: [:0]const u8,
        face: freetype.Face,
        face_index: i32,
    ) error{OutOfMemory}!Record {
        const family_name = try dupFaceString(alloc, face.handle.*.family_name, "Unknown");
        errdefer alloc.free(family_name);

        const style_name = try dupFaceString(alloc, face.handle.*.style_name, "Regular");
        errdefer alloc.free(style_name);

        const full_name = try buildFullName(alloc, family_name, style_name);
        errdefer alloc.free(full_name);

        const typographic_family = try typographicName(
            alloc,
            face,
            name_id_typographic_family,
        );
        errdefer if (typographic_family) |name| alloc.free(name);

        const typographic_style = try typographicName(
            alloc,
            face,
            name_id_typographic_subfamily,
        );
        errdefer if (typographic_style) |name| alloc.free(name);

        const style_flags = face.handle.*.style_flags;
        const face_flags = face.handle.*.face_flags;

        return .{
            .path = try alloc.dupeZ(u8, path),
            .face_index = face_index,
            .family_name = family_name,
            .style_name = style_name,
            .full_name = full_name,
            .typographic_family = typographic_family,
            .typographic_style = typographic_style,
            .weight = weightClass(face),
            .monospace = face_flags & freetype.c.FT_FACE_FLAG_FIXED_WIDTH != 0,
            .bold = style_flags & freetype.c.FT_STYLE_FLAG_BOLD != 0,
            .italic = style_flags & freetype.c.FT_STYLE_FLAG_ITALIC != 0 or
                containsIgnoreCase(style_name, "oblique"),
            .color = face.hasColor() or face.hasSBIX(),
            .variable = face.hasMultipleMasters(),
            .has_codepoint = false,
            .charset = null,
        };
    }

    //-------------------------------------------------------------------
    // Typographic names (OpenType name IDs 16/17) and weight

    /// A name-table entry, decoupled from FreeType so the selection logic
    /// is testable with injected data.
    const SfntNameEntry = struct {
        platform_id: u16,
        encoding_id: u16,
        language_id: u16,
        string: []const u8,
    };

    // OpenType name-table constants.
    const name_id_typographic_family = 16;
    const name_id_typographic_subfamily = 17;
    const platform_unicode = 0;
    const platform_macintosh = 1;
    const platform_microsoft = 3;
    const ms_encoding_unicode_bmp = 1;
    const ms_encoding_unicode_full = 10;
    const mac_encoding_roman = 0;
    const ms_lang_en_us = 0x0409;

    /// Read a typographic name (ID 16 or 17) from the face's name table,
    /// if present.
    fn typographicName(
        alloc: Allocator,
        face: freetype.Face,
        name_id: u16,
    ) error{OutOfMemory}!?[:0]const u8 {
        const count = face.getSfntNameCount();
        if (count == 0) return null;

        var entries_buf: [16]SfntNameEntry = undefined;
        var entries_len: usize = 0;
        for (0..count) |i| {
            if (entries_len >= entries_buf.len) break;
            const name = face.getSfntName(i) catch continue;
            if (name.name_id != name_id) continue;
            if (name.string == null) continue;
            entries_buf[entries_len] = .{
                .platform_id = @intCast(name.platform_id),
                .encoding_id = @intCast(name.encoding_id),
                .language_id = @intCast(name.language_id),
                .string = name.string[0..name.string_len],
            };
            entries_len += 1;
        }

        return try pickSfntName(alloc, entries_buf[0..entries_len]);
    }

    /// Pick and decode the best name-table candidate. Preference:
    /// Microsoft/Unicode en-US, then any-English, then any language, then
    /// Unicode platform, then Mac Roman (ASCII only).
    fn pickSfntName(
        alloc: Allocator,
        entries: []const SfntNameEntry,
    ) error{OutOfMemory}!?[:0]const u8 {
        var best: ?SfntNameEntry = null;
        var best_rank: u8 = 0;
        for (entries) |entry| {
            const rank = sfntNameRank(entry) orelse continue;
            if (rank > best_rank) {
                best_rank = rank;
                best = entry;
            }
        }
        const entry = best orelse return null;

        if (entry.platform_id == platform_macintosh) {
            // Treated as ASCII; sfntNameRank already rejected high bytes.
            return try alloc.dupeZ(u8, entry.string);
        }
        return utf16BeToUtf8Alloc(alloc, entry.string) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf16 => return null,
        };
    }

    /// OS/2 usWeightClass for the face, or 0 when there is no usable OS/2
    /// table (FreeType reports version 0xFFFF for a synthesized one).
    fn weightClass(face: freetype.Face) u16 {
        const os2 = face.getSfntTable(.os2) orelse return 0;
        if (os2.version == 0xFFFF) return 0;
        const raw: u16 = os2.usWeightClass;
        // Pre-OpenType fonts use the 1-9 scale from the original TrueType
        // spec; normalize it to the 100-1000 scale.
        if (raw >= 1 and raw <= 9) return raw * 100;
        if (raw < 100 or raw > 1000) return 0;
        return raw;
    }

    /// Rank a name-table entry for family-name selection; null means the
    /// entry is not usable.
    fn sfntNameRank(entry: SfntNameEntry) ?u8 {
        switch (entry.platform_id) {
            platform_microsoft => {
                if (entry.encoding_id != ms_encoding_unicode_bmp and
                    entry.encoding_id != ms_encoding_unicode_full) return null;
                if (entry.language_id == ms_lang_en_us) return 5;
                // Primary language ID 0x09 is English (any region).
                if (entry.language_id & 0x3FF == 0x09) return 4;
                return 3;
            },
            platform_unicode => return 2,
            platform_macintosh => {
                if (entry.encoding_id != mac_encoding_roman) return null;
                for (entry.string) |byte| if (byte >= 0x80) return null;
                return 1;
            },
            else => return null,
        }
    }

    /// Decode a UTF-16 big-endian byte string (the encoding of Microsoft
    /// and Unicode platform name-table entries) to UTF-8.
    fn utf16BeToUtf8Alloc(
        alloc: Allocator,
        bytes: []const u8,
    ) error{ OutOfMemory, InvalidUtf16 }![:0]const u8 {
        if (bytes.len % 2 != 0) return error.InvalidUtf16;
        const n = bytes.len / 2;
        const units = try alloc.alloc(u16, n);
        defer alloc.free(units);
        for (0..n) |i| {
            units[i] = (@as(u16, bytes[2 * i]) << 8) | bytes[2 * i + 1];
        }
        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, units) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidUtf16,
        };
        defer alloc.free(utf8);
        return try alloc.dupeZ(u8, utf8);
    }

    //-------------------------------------------------------------------
    // Matching

    /// Filter records against the descriptor and return deep copies for
    /// the iterator. Must be called with the mutex held. Charsets are
    /// materialized (and cached on the master records) for every record
    /// that survives the name/style filters, because both codepoint
    /// filtering here and DeferredFace.hasCodepoint downstream need them.
    fn filterRecordsLocked(
        self: *Windows,
        alloc: Allocator,
        desc: Descriptor,
    ) ![]Record {
        var result: std.ArrayListUnmanaged(Record) = .{};
        errdefer {
            for (result.items) |*record| record.deinit(alloc);
            result.deinit(alloc);
        }

        // One FreeType library shared by every face this query has to
        // open, created only if some face actually needs inspection.
        var lib: ?freetype.Library = null;
        defer if (lib) |*l| l.deinit();

        for (self.records) |*record| {
            if (!matchesDescriptor(record.*, desc)) continue;

            // Codepoint filter. A cached charset answers with a binary
            // search; otherwise probe the face with a single char-index
            // lookup instead of enumerating its entire charset — a
            // codepoint-only fallback query visits nearly every record.
            if (desc.codepoint > 0) {
                const contains = if (record.charset) |charset|
                    charsetHasCodepoint(charset, desc.codepoint)
                else
                    faceHasCodepoint(&lib, record.path, record.face_index, desc.codepoint);
                if (!contains) continue;
            }

            // Records handed to the iterator must carry a materialized
            // charset for DeferredFace.hasCodepoint, so compute and cache
            // it — but only for these survivors.
            _ = self.ensureCharsetLocked(&lib, record);

            var copy = try copyRecord(alloc, record.*);
            copy.has_codepoint = desc.codepoint > 0;
            errdefer copy.deinit(alloc);
            try result.append(alloc, copy);
        }

        return try result.toOwnedSlice(alloc);
    }

    /// Cheap membership probe: open the face and look up one char index
    /// instead of enumerating the full charset. Any failure counts as
    /// "does not contain".
    fn faceHasCodepoint(
        lib: *?freetype.Library,
        path: [:0]const u8,
        face_index: i32,
        codepoint: u32,
    ) bool {
        const l = sharedLibrary(lib) orelse return false;
        const face = l.initFace(path, face_index) catch return false;
        defer face.deinit();
        face.selectCharmap(.unicode) catch return false;
        return face.getCharIndex(codepoint) != null;
    }

    /// Return the record's charset, computing and caching it on first
    /// use. Must be called with the mutex held. Extraction failures are
    /// cached as an empty heap-owned slice so a broken font isn't
    /// re-parsed on every query; out-of-memory skips the cache entirely
    /// so a later query can retry.
    fn ensureCharsetLocked(
        self: *Windows,
        lib: *?freetype.Library,
        record: *Record,
    ) []const u32 {
        if (record.charset) |charset| return charset;

        const charset = computeCharset(self.alloc, lib, record.path, record.face_index) catch |err| switch (err) {
            error.OutOfMemory => return &.{},
            else => blk: {
                log.debug("windows font discovery charset failed path={s} index={} err={}", .{
                    record.path, record.face_index, err,
                });
                break :blk self.alloc.alloc(u32, 0) catch return &.{};
            },
        };
        record.charset = charset;
        return charset;
    }

    fn computeCharset(
        alloc: Allocator,
        lib: *?freetype.Library,
        path: [:0]const u8,
        face_index: i32,
    ) ![]const u32 {
        const l = sharedLibrary(lib) orelse return error.LibraryInitFailed;
        const face = try l.initFace(path, face_index);
        defer face.deinit();
        return try extractCharset(alloc, face);
    }

    /// Return the query-shared FreeType library, creating it on first use.
    fn sharedLibrary(lib: *?freetype.Library) ?freetype.Library {
        if (lib.*) |l| return l;
        const created = freetype.Library.init() catch |err| {
            log.warn("windows font discovery freetype init failed err={}", .{err});
            return null;
        };
        lib.* = created;
        return created;
    }

    fn extractCharset(alloc: Allocator, face: freetype.Face) ![]const u32 {
        // Select unicode charmap for enumeration; if unavailable, treat as empty
        if (freetype.c.FT_Select_Charmap(face.handle, freetype.c.FT_ENCODING_UNICODE) != 0) {
            return try alloc.dupe(u32, &.{});
        }

        var codepoints: std.ArrayListUnmanaged(u32) = .{};
        errdefer codepoints.deinit(alloc);

        var glyph_index: u32 = undefined;
        var charcode = freetype.c.FT_Get_First_Char(face.handle, &glyph_index);
        while (glyph_index != 0) {
            try codepoints.append(alloc, @intCast(charcode));
            charcode = freetype.c.FT_Get_Next_Char(face.handle, charcode, &glyph_index);
        }

        return try codepoints.toOwnedSlice(alloc);
    }

    fn copyRecord(alloc: Allocator, record: Record) error{OutOfMemory}!Record {
        const path = try alloc.dupeZ(u8, record.path);
        errdefer alloc.free(path);
        const family_name = try alloc.dupeZ(u8, record.family_name);
        errdefer alloc.free(family_name);
        const style_name = try alloc.dupeZ(u8, record.style_name);
        errdefer alloc.free(style_name);
        const full_name = try alloc.dupeZ(u8, record.full_name);
        errdefer alloc.free(full_name);
        const typographic_family: ?[:0]const u8 = if (record.typographic_family) |name|
            try alloc.dupeZ(u8, name)
        else
            null;
        errdefer if (typographic_family) |name| alloc.free(name);
        const typographic_style: ?[:0]const u8 = if (record.typographic_style) |name|
            try alloc.dupeZ(u8, name)
        else
            null;
        errdefer if (typographic_style) |name| alloc.free(name);
        const charset = try alloc.dupe(u32, record.charset orelse &.{});

        var copy = record;
        copy.path = path;
        copy.family_name = family_name;
        copy.style_name = style_name;
        copy.full_name = full_name;
        copy.typographic_family = typographic_family;
        copy.typographic_style = typographic_style;
        copy.charset = charset;
        return copy;
    }

    fn matchesDescriptor(record: Record, desc: Descriptor) bool {
        if (desc.family) |family| {
            if (std.ascii.eqlIgnoreCase(family, "monospace")) {
                if (!record.monospace) return false;
            } else if (!containsIgnoreCase(record.family_name, family) and
                !containsIgnoreCase(record.full_name, family) and
                !(record.typographic_family != null and
                    containsIgnoreCase(record.typographic_family.?, family)))
            {
                return false;
            }
        }

        if (desc.style) |style| {
            if (!containsIgnoreCase(record.style_name, style) and
                !containsIgnoreCase(record.full_name, style) and
                !(record.typographic_style != null and
                    containsIgnoreCase(record.typographic_style.?, style)))
            {
                return false;
            }
        }

        if (desc.bold and !isBold(record)) return false;
        if (desc.italic and !record.italic) return false;
        if (desc.monospace and !record.monospace) return false;

        return true;
    }

    /// Whether the face is a bold face. Weight-split families (Nerd Fonts
    /// among them) ship the heavy weights as separate families whose
    /// subfamily is "Regular", so the style flag alone misses them; the
    /// OS/2 weight class is the reliable signal. 600 is SemiBold, the
    /// lightest weight worth substituting for a bold request.
    fn isBold(record: Record) bool {
        return record.bold or record.weight >= 600;
    }

    /// Distance from the weight the descriptor asks for, as a small
    /// "higher is better" score. Faces with no OS/2 table fall back to
    /// their style flag.
    fn weightRank(desc: Descriptor, record: Record) u32 {
        const want: u16 = if (desc.bold) 700 else 400;
        const have: u16 = if (record.weight != 0)
            record.weight
        else if (record.bold) 700 else 400;
        const diff = if (have > want) have - want else want - have;
        const steps = diff / 50;
        return if (steps >= weight_rank_max) 0 else weight_rank_max - steps;
    }

    /// Maximum value of `weightRank`, i.e. an exact weight match. Four
    /// bits wide so the rank fits the score field reserved for it.
    const weight_rank_max: u32 = 15;

    fn score(desc: Descriptor, record: Record) u32 {
        var result: u32 = 0;

        if (desc.codepoint > 0 and record.has_codepoint) result |= 1 << 20;

        if (desc.family) |family| {
            if (std.ascii.eqlIgnoreCase(record.family_name, family)) result |= 1 << 19;
            if (record.typographic_family) |typographic| {
                if (std.ascii.eqlIgnoreCase(typographic, family)) result |= 1 << 19;
                if (containsIgnoreCase(typographic, family)) result |= 1 << 17;
            }
            if (std.ascii.eqlIgnoreCase(record.full_name, family)) result |= 1 << 18;
            if (containsIgnoreCase(record.family_name, family)) result |= 1 << 17;
        }

        if (desc.style) |style| {
            if (std.ascii.eqlIgnoreCase(record.style_name, style)) result |= 1 << 16;
            if (containsIgnoreCase(record.style_name, style)) result |= 1 << 15;
            if (record.typographic_style) |typographic| {
                if (std.ascii.eqlIgnoreCase(typographic, style)) result |= 1 << 16;
                if (containsIgnoreCase(typographic, style)) result |= 1 << 15;
            }
        }

        if (desc.monospace and record.monospace) result |= 1 << 14;

        // Style agreement, not just style reward: a request with no bold
        // or italic asked for the Regular face, so a bold face has to
        // score *below* it. Otherwise every face of a family that shares
        // one family name (Nerd Fonts v3, where the typographic family is
        // the only name the user is told to configure) ties on the family
        // bits above and the winner is whichever the scan saw first.
        if (desc.bold == isBold(record)) result |= 1 << 13;
        if (desc.italic == record.italic) result |= 1 << 12;

        // Weight proximity breaks ties inside the winning style bucket,
        // e.g. Regular (400) over Medium (500) for an unstyled request.
        result |= weightRank(desc, record) << 8;

        if (desc.variations.len > 0 and record.variable) result |= 1 << 7;
        if (record.color) result |= 1 << 6;

        return result;
    }

    fn charsetHasCodepoint(charset: []const u32, codepoint: u32) bool {
        const result = std.sort.binarySearch(u32, charset, codepoint, struct {
            fn order(target: u32, item: u32) std.math.Order {
                return std.math.order(target, item);
            }
        }.order);
        return result != null;
    }

    fn supportedFontFile(name: []const u8) bool {
        const ext = std.fs.path.extension(name);
        return std.ascii.eqlIgnoreCase(ext, ".ttf") or
            std.ascii.eqlIgnoreCase(ext, ".otf") or
            std.ascii.eqlIgnoreCase(ext, ".ttc") or
            std.ascii.eqlIgnoreCase(ext, ".otc");
    }

    fn dupFaceString(
        alloc: Allocator,
        ptr: anytype,
        fallback: []const u8,
    ) ![:0]const u8 {
        const bytes: []const u8 = if (ptr) |value|
            std.mem.span(value)
        else
            fallback;
        return try alloc.dupeZ(u8, bytes);
    }

    fn buildFullName(
        alloc: Allocator,
        family_name: []const u8,
        style_name: []const u8,
    ) ![:0]const u8 {
        if (style_name.len == 0 or std.ascii.eqlIgnoreCase(style_name, "Regular")) {
            return try alloc.dupeZ(u8, family_name);
        }

        const full_name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ family_name, style_name });
        defer alloc.free(full_name);
        return try alloc.dupeZ(u8, full_name);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(
                haystack[i .. i + needle.len],
                needle,
            )) return true;
        }

        return false;
    }

    //-------------------------------------------------------------------
    // Staleness tracking for refresh()

    /// Change signal for the font sources. Installing or removing a font
    /// updates the containing directory's mtime (NTFS bumps it when
    /// direct children are added/removed) and/or the HKCU font key's
    /// last-write time, so those events are detected. Overwriting an
    /// existing font file in place changes neither and is deliberately
    /// not detected — the next install/uninstall or app restart picks it
    /// up, and tracking per-file mtimes would make every staleness check
    /// a full directory walk.
    const ScanState = struct {
        system_mtime: ?i128,
        user_mtime: ?i128,
        registry_write: ?u64,

        fn eql(a: ScanState, b: ScanState) bool {
            return std.meta.eql(a, b);
        }
    };

    fn scanState(self: *const Windows) ScanState {
        return .{
            .system_mtime = if (self.system_dir) |dir| dirMtime(dir) else null,
            .user_mtime = if (self.user_dir) |dir| dirMtime(dir) else null,
            .registry_write = registryLastWrite(),
        };
    }

    fn dirMtime(path: [:0]const u8) ?i128 {
        var dir = std.fs.openDirAbsolute(path, .{}) catch return null;
        defer dir.close();
        const stat = dir.stat() catch return null;
        return stat.mtime;
    }

    fn registryLastWrite() ?u64 {
        var hkey: winreg.HKEY = 0;
        if (winreg.RegOpenKeyExW(
            winreg.HKEY_CURRENT_USER,
            fonts_subkey,
            0,
            winreg.KEY_READ,
            &hkey,
        ) != winreg.ERROR_SUCCESS) return null;
        defer _ = winreg.RegCloseKey(hkey);

        var ft: winreg.FILETIME = .{ .low = 0, .high = 0 };
        if (winreg.RegQueryInfoKeyW(
            hkey,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            &ft,
        ) != winreg.ERROR_SUCCESS) return null;
        return (@as(u64, ft.high) << 32) | ft.low;
    }

    //-------------------------------------------------------------------
    // Registry bindings (mirrors the pattern in src/apprt/win32.zig)

    const fonts_subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
    );

    const winreg = struct {
        const HKEY = usize;
        const HKEY_CURRENT_USER: HKEY = 0x80000001;
        const KEY_READ: u32 = 0x20019;
        const ERROR_SUCCESS: i32 = 0;
        const ERROR_MORE_DATA: i32 = 234;
        const ERROR_NO_MORE_ITEMS: i32 = 259;
        const REG_SZ: u32 = 1;
        const REG_EXPAND_SZ: u32 = 2;
        const FILETIME = extern struct { low: u32, high: u32 };

        extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, ulOptions: u32, samDesired: u32, phkResult: *HKEY) callconv(.winapi) i32;
        extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;
        extern "advapi32" fn RegQueryInfoKeyW(hKey: HKEY, lpClass: ?[*]u16, lpcchClass: ?*u32, lpReserved: ?*u32, lpcSubKeys: ?*u32, lpcbMaxSubKeyLen: ?*u32, lpcbMaxClassLen: ?*u32, lpcValues: ?*u32, lpcbMaxValueNameLen: ?*u32, lpcbMaxValueLen: ?*u32, lpcbSecurityDescriptor: ?*u32, lpftLastWriteTime: ?*FILETIME) callconv(.winapi) i32;
        extern "advapi32" fn RegEnumValueW(hKey: HKEY, dwIndex: u32, lpValueName: [*]u16, lpcchValueName: *u32, lpReserved: ?*u32, lpType: ?*u32, lpData: ?[*]u8, lpcbData: ?*u32) callconv(.winapi) i32;
        extern "kernel32" fn ExpandEnvironmentStringsW(lpSrc: [*:0]const u16, lpDst: ?[*]u16, nSize: u32) callconv(.winapi) u32;
    };
};

//-----------------------------------------------------------------------
// Tests. The helpers below are pure and run on every host; tests that
// touch the real filesystem, registry, or FreeType faces skip themselves
// off-Windows.

const testing = std.testing;

test "windowsSupportedFontFileHelper" {
    try testing.expect(Windows.supportedFontFile("foo.ttf"));
    try testing.expect(Windows.supportedFontFile("foo.OTF"));
    try testing.expect(Windows.supportedFontFile("foo.ttc"));
    try testing.expect(!Windows.supportedFontFile("foo.txt"));
    try testing.expect(!Windows.supportedFontFile("foo.fon"));
    try testing.expect(!Windows.supportedFontFile("foo"));
}

fn testRecord() Windows.Record {
    return .{
        .path = undefined,
        .face_index = 0,
        .family_name = "Cascadia Mono",
        .style_name = "Bold Italic",
        .full_name = "Cascadia Mono Bold Italic",
        .typographic_family = null,
        .typographic_style = null,
        .weight = 700,
        .monospace = true,
        .bold = true,
        .italic = true,
        .color = false,
        .variable = true,
        .has_codepoint = true,
        .charset = null,
    };
}

test "windowsDescriptorMatchingHelper" {
    const record = testRecord();

    try testing.expect(Windows.matchesDescriptor(record, .{
        .family = "cascadia mono",
        .bold = true,
        .italic = true,
        .monospace = true,
    }));
    try testing.expect(!Windows.matchesDescriptor(record, .{
        .family = "Segoe UI",
    }));
}

test "windowsTypographicFamilyMatching" {
    // A weight-split family: the legacy family (name ID 1) that FreeType
    // reports differs from the typographic family (name ID 16) shown by
    // the Windows Fonts UI.
    var record = testRecord();
    record.family_name = "Cascadia Mono SemiLight";
    record.full_name = "Cascadia Mono SemiLight Bold Italic";
    record.typographic_family = "Cascadia Mono";

    try testing.expect(Windows.matchesDescriptor(record, .{
        .family = "Cascadia Mono",
    }));

    // Exact typographic match scores at the same tier as exact legacy
    // family match.
    const typographic_score = Windows.score(.{ .family = "cascadia mono" }, record);
    record.typographic_family = null;
    record.family_name = "Cascadia Mono";
    record.full_name = "Cascadia Mono Bold Italic";
    const legacy_score = Windows.score(.{ .family = "cascadia mono" }, record);
    try testing.expect(typographic_score & (1 << 19) != 0);
    try testing.expect(legacy_score & (1 << 19) != 0);
}

/// The four faces of a Nerd Fonts v3 family as the Windows scan sees
/// them: one legacy family name (name ID 1) shared by every face, one
/// typographic family (name ID 16) shared by every face, and the style
/// carried only by the subfamily name, the style flags and OS/2 weight.
fn nerdFontRecords() [4]Windows.Record {
    const base: Windows.Record = .{
        .path = undefined,
        .face_index = 0,
        .family_name = "JetBrainsMono NFM",
        .style_name = "Regular",
        .full_name = "JetBrainsMono NFM",
        .typographic_family = "JetBrainsMono Nerd Font Mono",
        .typographic_style = null,
        .weight = 400,
        .monospace = true,
        .bold = false,
        .italic = false,
        .color = false,
        .variable = false,
        .has_codepoint = false,
        .charset = null,
    };

    var bold = base;
    bold.style_name = "Bold";
    bold.full_name = "JetBrainsMono NFM Bold";
    bold.weight = 700;
    bold.bold = true;

    var italic = base;
    italic.style_name = "Italic";
    italic.full_name = "JetBrainsMono NFM Italic";
    italic.italic = true;

    var bold_italic = base;
    bold_italic.style_name = "Bold Italic";
    bold_italic.full_name = "JetBrainsMono NFM Bold Italic";
    bold_italic.weight = 700;
    bold_italic.bold = true;
    bold_italic.italic = true;

    // Scan order is directory order, which puts Bold ahead of Regular.
    return .{ bold, bold_italic, italic, base };
}

/// Mirror of discover(): filter, then take the highest score, the first
/// of equal scores winning as it does under the stable sort.
fn bestRecord(records: []const Windows.Record, desc: Descriptor) ?Windows.Record {
    var best: ?Windows.Record = null;
    var best_score: u32 = 0;
    for (records) |record| {
        if (!Windows.matchesDescriptor(record, desc)) continue;
        const current = Windows.score(desc, record);
        if (best == null or current > best_score) {
            best = record;
            best_score = current;
        }
    }
    return best;
}

fn bestStyleName(records: []const Windows.Record, desc: Descriptor) ?[]const u8 {
    const record = bestRecord(records, desc) orelse return null;
    return record.style_name;
}

fn bestFamilyName(records: []const Windows.Record, desc: Descriptor) ?[]const u8 {
    const record = bestRecord(records, desc) orelse return null;
    return record.family_name;
}

test "windowsStyleSelectionByTypographicFamily" {
    const records = nerdFontRecords();
    const typographic = "JetBrainsMono Nerd Font Mono";
    const legacy = "JetBrainsMono NFM";

    // The regression: every face shares the typographic family, so the
    // family bits tie and the unstyled request used to take whichever
    // face the scan saw first, which is Bold.
    try testing.expectEqualStrings("Regular", bestStyleName(&records, .{
        .family = typographic,
    }).?);
    try testing.expectEqualStrings("Bold", bestStyleName(&records, .{
        .family = typographic,
        .bold = true,
    }).?);
    try testing.expectEqualStrings("Italic", bestStyleName(&records, .{
        .family = typographic,
        .italic = true,
    }).?);
    try testing.expectEqualStrings("Bold Italic", bestStyleName(&records, .{
        .family = typographic,
        .bold = true,
        .italic = true,
    }).?);

    // The legacy-name path resolved correctly before this change, because
    // the Regular face's full name equals the family name and broke the
    // tie. It must keep doing so.
    try testing.expectEqualStrings("Regular", bestStyleName(&records, .{
        .family = legacy,
    }).?);
    try testing.expectEqualStrings("Bold", bestStyleName(&records, .{
        .family = legacy,
        .bold = true,
    }).?);
    try testing.expectEqualStrings("Bold Italic", bestStyleName(&records, .{
        .family = legacy,
        .bold = true,
        .italic = true,
    }).?);

    // An explicit style string still outranks the style flags, so
    // font-style can name a face the flags would rank lower.
    try testing.expectEqualStrings("Bold", bestStyleName(&records, .{
        .family = typographic,
        .style = "Bold",
    }).?);
}

test "windowsStyleSelectionWeightSplitFamily" {
    // Weight-split faces: the legacy family carries the weight and the
    // subfamily is "Regular", so only the OS/2 weight tells them apart.
    var light = nerdFontRecords()[3];
    light.family_name = "JetBrainsMono NFM Light";
    light.full_name = "JetBrainsMono NFM Light";
    light.typographic_style = "Light";
    light.weight = 300;

    var medium = light;
    medium.family_name = "JetBrainsMono NFM Medium";
    medium.full_name = "JetBrainsMono NFM Medium";
    medium.typographic_style = "Medium";
    medium.weight = 500;

    var extra_bold = light;
    extra_bold.family_name = "JetBrainsMono NFM ExtraBold";
    extra_bold.full_name = "JetBrainsMono NFM ExtraBold";
    extra_bold.typographic_style = "ExtraBold";
    extra_bold.weight = 800;

    const regular = nerdFontRecords()[3];
    const records = [_]Windows.Record{ light, medium, extra_bold, regular };
    const family = "JetBrainsMono Nerd Font Mono";

    // Every candidate here has style name "Regular", so the weight class
    // is the only discriminator for an unstyled request.
    try testing.expectEqualStrings("JetBrainsMono NFM", bestFamilyName(&records, .{
        .family = family,
    }).?);

    // A bold request has no bold-flagged face to take, so it falls to the
    // heaviest weight instead of being filtered down to nothing.
    try testing.expectEqualStrings("JetBrainsMono NFM ExtraBold", bestFamilyName(&records, .{
        .family = family,
        .bold = true,
    }).?);

    // The typographic subfamily is matchable as a style string even
    // though the legacy subfamily says "Regular".
    try testing.expectEqualStrings("JetBrainsMono NFM Medium", bestFamilyName(&records, .{
        .family = family,
        .style = "Medium",
    }).?);
}

test "windowsInspectFaceNerdFontFixture" {
    // End to end over the real Nerd Fonts v3 faces the repo vendors: the
    // names, style flags and weights come out of FreeType rather than out
    // of a fixture struct, and the unstyled request must land on Regular.
    const alloc = testing.allocator;
    const embedded = @import("embedded.zig");

    var lib = try freetype.Library.init();
    defer lib.deinit();

    const files = [_]struct { path: [:0]const u8, data: []const u8 }{
        .{ .path = "\\fixture\\JetBrainsMonoNerdFont-Bold.ttf", .data = embedded.test_nerd_font_bold },
        .{ .path = "\\fixture\\JetBrainsMonoNerdFont-BoldItalic.ttf", .data = embedded.test_nerd_font_bold_italic },
        .{ .path = "\\fixture\\JetBrainsMonoNerdFont-Italic.ttf", .data = embedded.test_nerd_font_italic },
        .{ .path = "\\fixture\\JetBrainsMonoNerdFont-Regular.ttf", .data = embedded.test_nerd_font },
    };

    var records: [files.len]Windows.Record = undefined;
    var built: usize = 0;
    defer for (records[0..built]) |*record| record.deinit(alloc);
    for (files, 0..) |file, i| {
        const face = try lib.initMemoryFace(file.data, 0);
        defer face.deinit();
        records[i] = try Windows.inspectFace(alloc, file.path, face, 0);
        built += 1;
    }

    // What the scan reads off the files.
    try testing.expectEqualStrings("JetBrainsMono NF", records[3].family_name);
    try testing.expectEqualStrings("JetBrainsMono Nerd Font", records[3].typographic_family.?);
    try testing.expectEqual(@as(u16, 400), records[3].weight);
    try testing.expectEqual(@as(u16, 700), records[0].weight);
    try testing.expect(records[0].bold);
    try testing.expect(!records[3].bold);

    const family = "JetBrainsMono Nerd Font";
    try testing.expectEqualStrings("Regular", bestStyleName(&records, .{ .family = family }).?);
    try testing.expectEqualStrings("Bold", bestStyleName(&records, .{
        .family = family,
        .bold = true,
    }).?);
    try testing.expectEqualStrings("Italic", bestStyleName(&records, .{
        .family = family,
        .italic = true,
    }).?);
    try testing.expectEqualStrings("Bold Italic", bestStyleName(&records, .{
        .family = family,
        .bold = true,
        .italic = true,
    }).?);
}

test "windowsRegistryFontPathResolve" {
    const alloc = testing.allocator;
    const system_dir: []const u8 = "C:\\Windows\\Fonts";

    // Absolute paths pass through untouched.
    {
        const got = (try Windows.resolveRegistryFontPath(
            alloc,
            "C:\\Users\\me\\AppData\\Local\\Microsoft\\Windows\\Fonts\\Custom.ttf",
            system_dir,
        )).?;
        defer alloc.free(got);
        try testing.expectEqualStrings(
            "C:\\Users\\me\\AppData\\Local\\Microsoft\\Windows\\Fonts\\Custom.ttf",
            got,
        );
    }

    // UNC paths are absolute too.
    {
        const got = (try Windows.resolveRegistryFontPath(
            alloc,
            "\\\\server\\share\\font.otf",
            system_dir,
        )).?;
        defer alloc.free(got);
        try testing.expectEqualStrings("\\\\server\\share\\font.otf", got);
    }

    // Bare file names resolve against the system fonts directory.
    {
        const got = (try Windows.resolveRegistryFontPath(alloc, "arial.ttf", system_dir)).?;
        defer alloc.free(got);
        try testing.expectEqualStrings("C:\\Windows\\Fonts\\arial.ttf", got);
    }

    // Unsupported extensions and empty values resolve to nothing.
    try testing.expect(try Windows.resolveRegistryFontPath(alloc, "vgaoem.fon", system_dir) == null);
    try testing.expect(try Windows.resolveRegistryFontPath(alloc, "", system_dir) == null);
    try testing.expect(try Windows.resolveRegistryFontPath(alloc, "  ", system_dir) == null);

    // A bare name with no system dir available resolves to nothing.
    try testing.expect(try Windows.resolveRegistryFontPath(alloc, "arial.ttf", null) == null);
}

test "windowsFontPathDedupe" {
    const alloc = testing.allocator;

    var paths: std.ArrayListUnmanaged([:0]const u8) = .{};
    defer {
        for (paths.items) |path| alloc.free(path);
        paths.deinit(alloc);
    }
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        seen.deinit(alloc);
    }

    try Windows.addUniquePath(alloc, &paths, &seen, "C:\\Windows\\Fonts\\Arial.TTF");
    try Windows.addUniquePath(alloc, &paths, &seen, "c:\\windows\\fonts\\arial.ttf");
    try Windows.addUniquePath(alloc, &paths, &seen, "C:\\Windows\\Fonts\\Consola.ttf");

    try testing.expectEqual(@as(usize, 2), paths.items.len);
    try testing.expectEqualStrings("C:\\Windows\\Fonts\\Arial.TTF", paths.items[0]);
    try testing.expectEqualStrings("C:\\Windows\\Fonts\\Consola.ttf", paths.items[1]);
}

test "windowsUtf16BeDecode" {
    const alloc = testing.allocator;

    // ASCII.
    {
        const got = try Windows.utf16BeToUtf8Alloc(alloc, "\x00A\x00r\x00i\x00a\x00l");
        defer alloc.free(got);
        try testing.expectEqualStrings("Arial", got);
    }

    // Non-ASCII BMP character (é = U+00E9).
    {
        const got = try Windows.utf16BeToUtf8Alloc(alloc, "\x00\xe9");
        defer alloc.free(got);
        try testing.expectEqualStrings("é", got);
    }

    // Surrogate pair (𝄞 = U+1D11E = D834 DD1E).
    {
        const got = try Windows.utf16BeToUtf8Alloc(alloc, "\xd8\x34\xdd\x1e");
        defer alloc.free(got);
        try testing.expectEqualStrings("𝄞", got);
    }

    // Odd byte counts are invalid.
    try testing.expectError(error.InvalidUtf16, Windows.utf16BeToUtf8Alloc(alloc, "\x00"));
}

test "windowsSfntNamePick" {
    const alloc = testing.allocator;
    const be = struct {
        // "Best" in UTF-16BE.
        const best = "\x00B\x00e\x00s\x00t";
        // "Other" in UTF-16BE.
        const other = "\x00O\x00t\x00h\x00e\x00r";
    };

    // Microsoft en-US beats Mac Roman.
    {
        const got = (try Windows.pickSfntName(alloc, &.{
            .{ .platform_id = 1, .encoding_id = 0, .language_id = 0, .string = "MacName" },
            .{ .platform_id = 3, .encoding_id = 1, .language_id = 0x0409, .string = be.best },
        })).?;
        defer alloc.free(got);
        try testing.expectEqualStrings("Best", got);
    }

    // Any-English beats non-English.
    {
        const got = (try Windows.pickSfntName(alloc, &.{
            .{ .platform_id = 3, .encoding_id = 1, .language_id = 0x0407, .string = be.other },
            .{ .platform_id = 3, .encoding_id = 1, .language_id = 0x0809, .string = be.best },
        })).?;
        defer alloc.free(got);
        try testing.expectEqualStrings("Best", got);
    }

    // Mac Roman ASCII works as a last resort.
    {
        const got = (try Windows.pickSfntName(alloc, &.{
            .{ .platform_id = 1, .encoding_id = 0, .language_id = 0, .string = "MacName" },
        })).?;
        defer alloc.free(got);
        try testing.expectEqualStrings("MacName", got);
    }

    // Mac Roman with high bytes is not decodable; nothing usable → null.
    try testing.expect((try Windows.pickSfntName(alloc, &.{
        .{ .platform_id = 1, .encoding_id = 0, .language_id = 0, .string = "Caf\xe9" },
    })) == null);
    try testing.expect((try Windows.pickSfntName(alloc, &.{})) == null);
}

test "windowsCharsetHasCodepoint" {
    const charset = [_]u32{ 'A', 'B', 'Z', 0x1F600 };
    try testing.expect(Windows.charsetHasCodepoint(&charset, 'A'));
    try testing.expect(Windows.charsetHasCodepoint(&charset, 0x1F600));
    try testing.expect(!Windows.charsetHasCodepoint(&charset, 'C'));
    try testing.expect(!Windows.charsetHasCodepoint(&.{}, 'A'));
}

test "windowsScanStateEql" {
    const a: Windows.ScanState = .{ .system_mtime = 1, .user_mtime = null, .registry_write = 42 };
    try testing.expect(a.eql(.{ .system_mtime = 1, .user_mtime = null, .registry_write = 42 }));
    try testing.expect(!a.eql(.{ .system_mtime = 2, .user_mtime = null, .registry_write = 42 }));
    try testing.expect(!a.eql(.{ .system_mtime = 1, .user_mtime = 0, .registry_write = 42 }));
    try testing.expect(!a.eql(.{ .system_mtime = 1, .user_mtime = null, .registry_write = null }));
}

test "windows discovery end to end" {
    // The comptime branch keeps the Windows-only body (init/refresh and
    // the advapi32/kernel32 externs behind them) out of semantic analysis
    // on other hosts entirely.
    if (comptime builtin.os.tag == .windows) {
        const alloc = testing.allocator;

        var disco = Windows.init();
        defer disco.deinit();

        // First refresh scans; an immediate second refresh must be a cheap
        // no-op (unchanged state) and must not invalidate anything.
        disco.refresh();
        disco.refresh();

        // Arial ships with every Windows install.
        {
            var it = try disco.discover(alloc, .{ .family = "Arial", .size = 12 });
            defer it.deinit();
            var face = (try it.next()) orelse return error.TestUnexpectedResult;
            defer face.deinit();
            try testing.expect(face.hasCodepoint('A', null));
        }

        // Codepoint fallback across all fonts.
        {
            var it = try disco.discover(alloc, .{ .codepoint = 'A', .size = 12 });
            defer it.deinit();
            var face = (try it.next()) orelse return error.TestUnexpectedResult;
            defer face.deinit();
            try testing.expect(face.hasCodepoint('A', null));
        }
    } else return error.SkipZigTest;
}
