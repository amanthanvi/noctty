//! This structure contains a set of SharedGrid structures keyed by
//! unique font configuration.
//!
//! Most terminals (surfaces) will share the same font configuration.
//! This structure allows expensive font information such as
//! the font atlas, glyph cache, font faces, etc. to be shared.
//!
//! This structure is thread-safe when the operations are documented
//! as thread-safe.
const SharedGridSet = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const font = @import("main.zig");
const CodepointResolver = font.CodepointResolver;
const Collection = font.Collection;
const Discover = font.Discover;
const Style = font.Style;
const Library = font.Library;
const Metrics = font.Metrics;
const CodepointMap = font.CodepointMap;
const DesiredSize = font.face.DesiredSize;
const Face = font.Face;
const SharedGrid = font.SharedGrid;
const discovery = font.discovery;
const configpkg = @import("../config/Config.zig");
const Config = configpkg;

const log = std.log.scoped(.font_shared_grid_set);

/// The allocator to use for all heap allocations.
alloc: Allocator,

/// The map of font configurations to SharedGrid instances.
map: Map = .{},

/// The font library that is used for all font groups.
font_lib: Library,

/// Font discovery mechanism.
font_discover: ?Discover = null,

/// Lock to protect multi-threaded access to the map.
lock: std.Thread.Mutex = .{},

/// Windows font metadata discovery can overlap runtime/window setup. The
/// worker only scans; it does not take `lock`, so a grid that needs no
/// font from the scan is built without waiting for it, and one that does
/// waits inside discovery, which also keeps the scan from running twice.
/// `deinit` stops a scan still in progress before joining it.
discovery_prefetch_thread: ?std.Thread = null,

pub const InitError = Library.InitError;

/// Initialize a new SharedGridSet.
pub fn init(alloc: Allocator) InitError!SharedGridSet {
    var font_lib = try Library.init(alloc);
    errdefer font_lib.deinit();

    return .{
        .alloc = alloc,
        .map = .{},
        .font_lib = font_lib,
    };
}

pub fn deinit(self: *SharedGridSet) void {
    if (self.discovery_prefetch_thread) |thread| {
        // Nothing needs the rest of the startup scan once the set goes
        // away, so stop it at its next file instead of waiting for every
        // installed font: on a cold disk that kept a windowless process
        // alive for seconds after its last window closed.
        if (comptime Discover != void and @hasDecl(Discover, "stopScan")) {
            if (self.font_discover) |*disco| disco.stopScan();
        }
        thread.join();
        self.discovery_prefetch_thread = null;
    }

    var it = self.map.iterator();
    while (it.next()) |entry| {
        entry.key_ptr.deinit();
        const v = entry.value_ptr.*;
        v.grid.deinit(self.alloc);
        self.alloc.destroy(v.grid);
        entry.value_ptr.missing.deinit(self.alloc);
    }
    self.map.deinit(self.alloc);

    if (comptime Discover != void) {
        if (self.font_discover) |*v| v.deinit();
    }

    self.font_lib.deinit();
}

/// Start Windows font discovery once the SharedGridSet has a stable address.
/// Spawn failure is harmless: the existing synchronous lookup remains the
/// fallback when the first surface requests its font grid.
pub fn startDiscoveryPrefetch(self: *SharedGridSet) void {
    if (comptime builtin.target.os.tag != .windows or
        Discover == void or
        !@hasDecl(Discover, "refresh")) return;
    if (self.discovery_prefetch_thread != null) return;

    const disco = disco: {
        self.lock.lock();
        defer self.lock.unlock();
        break :disco (self.discover() catch return) orelse return;
    };

    const thread = std.Thread.spawn(
        .{},
        discoveryPrefetchMain,
        .{disco},
    ) catch return;
    thread.setName("font-prefetch") catch {};
    self.discovery_prefetch_thread = thread;
}

pub fn discoveryPrefetchStarted(self: *const SharedGridSet) bool {
    return self.discovery_prefetch_thread != null;
}

fn discoveryPrefetchMain(disco: *Discover) void {
    disco.refresh();
}

/// Returns the number of cached grids.
pub fn count(self: *SharedGridSet) usize {
    self.lock.lock();
    defer self.lock.unlock();
    return self.map.count();
}

/// Initialize a SharedGrid for the given font configuration. If the
/// SharedGrid is not present it will be initialized with a ref count of
/// 1. If it is present, the ref count will be incremented.
///
/// This is NOT thread-safe.
///
/// The returned data (key and grid) should never be freed. The memory is
/// owned by the set and will be freed when the ref count reaches zero.
pub fn ref(
    self: *SharedGridSet,
    config: *const DerivedConfig,
    font_size: DesiredSize,
) !struct { Key, *SharedGrid } {
    var key = try Key.init(self.alloc, config, font_size);
    errdefer key.deinit();

    self.lock.lock();
    defer self.lock.unlock();

    const gop = try self.map.getOrPut(self.alloc, key);
    if (gop.found_existing) {
        log.debug("found cached grid for font config", .{});

        // We can deinit the key because we found a cached value.
        key.deinit();

        // Increment our ref count and return the cache
        gop.value_ptr.ref += 1;
        return .{ gop.key_ptr.*, gop.value_ptr.grid };
    }
    errdefer self.map.removeByPtr(gop.key_ptr);

    log.debug("initializing new grid for font config", .{});

    // A new font config, initialize the cache.
    const grid = try self.alloc.create(SharedGrid);
    errdefer self.alloc.destroy(grid);
    gop.value_ptr.* = .{
        .grid = grid,
        .ref = 1,
    };

    // The configured families no installed font matched, kept with the grid.
    var missing: MissingFamilies = .{};
    errdefer missing.deinit(self.alloc);

    grid.* = try .init(self.alloc, resolver: {
        // Build our collection. This is the expensive operation that
        // involves finding fonts, loading them (maybe, some are deferred),
        // etc.
        var c = try self.collection(&key, font_size, config, &missing);
        errdefer c.deinit(self.alloc);

        // Setup our enabled/disabled styles
        var styles = CodepointResolver.StyleStatus.initFill(true);
        styles.set(.bold, config.@"font-style-bold" != .false);
        styles.set(.italic, config.@"font-style-italic" != .false);
        styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

        // Init our resolver which just requires setting fields.
        break :resolver .{
            .collection = c,
            .styles = styles,
            .discover = try self.discover(),
            .codepoint_map = key.codepoint_map,
        };
    });
    errdefer grid.deinit(self.alloc);

    gop.value_ptr.missing = missing;
    return .{ gop.key_ptr.*, gop.value_ptr.grid };
}

/// The families the grid for `key` was configured with that no installed font
/// matched. Other configured or built-in families provide fallbacks. Names are
/// borrowed from the set and stay valid while `key` is referenced.
pub fn missingFamilies(self: *SharedGridSet, key: Key) []const [:0]const u8 {
    self.lock.lock();
    defer self.lock.unlock();
    const entry = self.map.get(key) orelse return &.{};
    return entry.missing.reportable();
}

/// Check explicit font families without needing an open terminal or a grid.
/// The result owns its names; the caller must deinit it with `alloc`.
/// A config with no named fonts does not initialize or wait for discovery.
pub fn configuredMissingFamilies(
    self: *SharedGridSet,
    alloc: Allocator,
    config: *const Config,
) !MissingFamilies {
    self.lock.lock();
    defer self.lock.unlock();

    var missing: MissingFamilies = .{};
    errdefer missing.deinit(alloc);
    if (comptime Discover == void) return missing;

    var refreshed = false;
    inline for (.{ "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic" }) |key| {
        for (@field(config, key).list.items) |family| {
            if (std.ascii.eqlIgnoreCase(family, MissingFamilies.embedded_family)) continue;
            const disco = try self.discover() orelse return missing;
            if (!refreshed) {
                if (comptime @hasDecl(Discover, "refreshExisting")) disco.refreshExisting();
                refreshed = true;
            }
            if (!try familyExists(disco, alloc, family)) try missing.note(alloc, family);
        }
    }
    return missing;
}

/// A failed styled lookup does not imply the family is absent. Discover
/// without style, size or variation constraints before reporting a miss.
fn familyExists(disco: *Discover, alloc: Allocator, family: [:0]const u8) !bool {
    if (std.ascii.eqlIgnoreCase(family, MissingFamilies.embedded_family)) return true;
    var it = try disco.discover(alloc, .{ .family = family });
    defer it.deinit();
    if (try it.next()) |value| {
        var face = value;
        face.deinit();
        return true;
    }
    return false;
}

/// Font families a configuration asked for and discovery found nothing for.
pub const MissingFamilies = struct {
    names: std.ArrayListUnmanaged([:0]const u8) = .empty,

    pub fn deinit(self: *MissingFamilies, alloc: Allocator) void {
        for (self.names.items) |name| alloc.free(name);
        self.names.deinit(alloc);
    }

    /// Note that no installed face belongs to `family`, regardless of style.
    /// Keep each family once across all configured styles and fallbacks.
    pub fn note(
        self: *MissingFamilies,
        alloc: Allocator,
        family: []const u8,
    ) Allocator.Error!void {
        if (std.ascii.eqlIgnoreCase(family, embedded_family)) return;
        for (self.names.items) |seen| {
            if (std.ascii.eqlIgnoreCase(seen, family)) return;
        }
        const owned = try alloc.dupeZ(u8, family);
        errdefer alloc.free(owned);
        try self.names.append(alloc, owned);
    }

    /// Each missing configured family is a problem even if a fallback works.
    pub fn reportable(self: *const MissingFamilies) []const [:0]const u8 {
        return self.names.items;
    }

    /// The family name of `font.embedded.variable`.
    const embedded_family = "JetBrains Mono";
};

/// Builds the Collection for the given configuration key and
/// initial font size.
fn collection(
    self: *SharedGridSet,
    key: *const Key,
    size: DesiredSize,
    config: *const DerivedConfig,
    missing: *MissingFamilies,
) !Collection {
    // A quick note on memory management:
    // - font_lib is owned by the SharedGridSet
    // - metric_modifiers is owned by the key which is freed only when
    //   the ref count for this grid reaches zero.
    const load_options: Collection.LoadOptions = .{
        .library = self.font_lib,
        .size = size,
        .freetype_load_flags = key.freetype_load_flags,
    };

    var c = Collection.init();
    errdefer c.deinit(self.alloc);
    c.load_options = load_options;
    c.metric_modifiers = key.metric_modifiers;

    // Search for fonts
    if (Discover != void) discover: {
        const disco = try self.discover() orelse {
            log.warn(
                "font discovery not available, cannot search for fonts",
                .{},
            );
            break :discover;
        };

        // Backends that support runtime rescanning (Windows) refresh their
        // font list here so that fonts installed while the app is running
        // are picked up on config reload. This is a cheap staleness check
        // when nothing changed. It never waits for or starts a first scan:
        // a grid that names no font needs nothing from it, and `discover`
        // below waits for it when a grid does. Other backends (fontconfig)
        // are unsafe to reinit and don't declare `refresh`.
        if (comptime @hasDecl(Discover, "refreshExisting")) disco.refreshExisting();

        // A buffer we use to store the font names for logging.
        var name_buf: [256]u8 = undefined;

        inline for (@typeInfo(Style).@"enum".fields) |field| {
            const style = @field(Style, field.name);
            for (key.descriptorsForStyle(style)) |desc| {
                {
                    var disco_it = try disco.discover(self.alloc, desc);
                    defer disco_it.deinit();
                    if (try disco_it.next()) |face| {
                        log.info("font {s}: {s}", .{
                            field.name,
                            try face.name(&name_buf),
                        });

                        _ = try c.addDeferred(self.alloc, face, .{
                            .style = style,
                            .fallback = false,
                            // No size adjustment for primary fonts.
                            .size_adjustment = .none,
                        });

                        continue;
                    }
                }

                // If there are variation configurations and we didn't find
                // the font, then we retry the discovery with all stylistic
                // bits set to false. This is because some fonts may not
                // set the stylistic bit in their table but still support
                // axes to mimic the style. At the time of writing, Berkeley
                // Mono Variable is like this. See #2140.
                if (style != .regular and desc.variations.len > 0) {
                    var disco_it = try disco.discover(self.alloc, desc: {
                        var copy = desc;
                        copy.bold = false;
                        copy.italic = false;
                        break :desc copy;
                    });
                    defer disco_it.deinit();
                    if (try disco_it.next()) |face| {
                        log.info("font {s}: {s}", .{
                            field.name,
                            try face.name(&name_buf),
                        });

                        _ = try c.addDeferred(self.alloc, face, .{
                            .style = style,
                            .fallback = false,
                            // No size adjustment for primary fonts.
                            .size_adjustment = .none,
                        });

                        continue;
                    }
                }

                log.warn("font {s} face not found: {s}", .{
                    field.name,
                    desc.family.?,
                });
                if (!try familyExists(disco, self.alloc, desc.family.?)) {
                    try missing.note(self.alloc, desc.family.?);
                }
            }
        }
    }

    // Complete our styles to ensure we have something to satisfy every
    // possible style request. We do this before adding our built-in font
    // because we want to ensure our built-in styles are fallbacks to
    // the configured styles.
    try c.completeStyles(self.alloc, config.@"font-synthetic-style");

    // Our built-in font will be used as a backup
    _ = try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.variable,
            load_options.faceOptions(),
        ),
        .{
            .style = .regular,
            .fallback = true,
            .size_adjustment = font.default_fallback_adjustment,
        },
    );
    try (try c.getFace(try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.variable,
            load_options.faceOptions(),
        ),
        .{
            .style = .bold,
            .fallback = true,
            .size_adjustment = font.default_fallback_adjustment,
        },
    ))).setVariations(
        &.{.{ .id = .init("wght"), .value = 700 }},
        load_options.faceOptions(),
    );
    _ = try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.variable_italic,
            load_options.faceOptions(),
        ),
        .{
            .style = .italic,
            .fallback = true,
            .size_adjustment = font.default_fallback_adjustment,
        },
    );
    try (try c.getFace(try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.variable_italic,
            load_options.faceOptions(),
        ),
        .{
            .style = .bold_italic,
            .fallback = true,
            .size_adjustment = font.default_fallback_adjustment,
        },
    ))).setVariations(
        &.{.{ .id = .init("wght"), .value = 700 }},
        load_options.faceOptions(),
    );

    // Nerd-font symbols fallback.
    _ = try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.symbols_nerd_font,
            load_options.faceOptions(),
        ),
        .{
            .style = .regular,
            .fallback = true,
            // No size adjustment for the symbols font.
            .size_adjustment = .none,
        },
    );

    // On macOS, always search for and add the Apple Emoji font
    // as our preferred emoji font for fallback. We do this in case
    // people add other emoji fonts to their system, we always want to
    // prefer the official one. Users can override this by explicitly
    // specifying a font-family for emoji.
    if (comptime builtin.target.os.tag.isDarwin() and Discover != void) apple_emoji: {
        const disco = try self.discover() orelse break :apple_emoji;
        var disco_it = try disco.discover(self.alloc, .{
            .family = "Apple Color Emoji",
        });
        defer disco_it.deinit();
        if (try disco_it.next()) |face| {
            _ = try c.addDeferred(self.alloc, face, .{
                .style = .regular,
                .fallback = true,
                // No size adjustment for emojis.
                .size_adjustment = .none,
            });
        }
    }

    // Emoji fallback. We don't include this on Mac since Mac is expected
    // to always have the Apple Emoji available on the system.
    if (comptime !builtin.target.os.tag.isDarwin() or Discover == void) {
        _ = try c.add(
            self.alloc,
            try .init(
                self.font_lib,
                font.embedded.emoji,
                load_options.faceOptions(),
            ),
            .{
                .style = .regular,
                .fallback = true,
                // No size adjustment for emojis.
                .size_adjustment = .none,
            },
        );
        _ = try c.add(
            self.alloc,
            try .init(
                self.font_lib,
                font.embedded.emoji_text,
                load_options.faceOptions(),
            ),
            .{
                .style = .regular,
                .fallback = true,
                // No size adjustment for emojis.
                .size_adjustment = .none,
            },
        );
    }

    return c;
}

/// Decrement the ref count for the given key. If the ref count is zero,
/// the grid will be deinitialized and removed from the map.j:w
pub fn deref(self: *SharedGridSet, key: Key) void {
    self.lock.lock();
    defer self.lock.unlock();

    const entry = self.map.getEntry(key) orelse return;
    assert(entry.value_ptr.ref >= 1);

    // If we have more than one reference, decrement and return.
    if (entry.value_ptr.ref > 1) {
        entry.value_ptr.ref -= 1;
        return;
    }

    // We are at a zero ref count so deinit the group and remove.
    entry.key_ptr.deinit();
    entry.value_ptr.grid.deinit(self.alloc);
    self.alloc.destroy(entry.value_ptr.grid);
    entry.value_ptr.missing.deinit(self.alloc);
    self.map.removeByPtr(entry.key_ptr);
}

/// Map of font configurations to grid instances. The grid
/// instances are pointers that are heap allocated so that they're
/// stable pointers across hash map resizes.
pub const Map = std.HashMapUnmanaged(
    Key,
    ReffedGrid,
    struct {
        const KeyType = Key;

        pub fn hash(ctx: @This(), k: KeyType) u64 {
            _ = ctx;
            return k.hashcode();
        }

        pub fn eql(ctx: @This(), a: KeyType, b: KeyType) bool {
            return ctx.hash(a) == ctx.hash(b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

/// Initialize once and return the font discovery mechanism. This remains
/// initialized throughout the lifetime of the application because some
/// font discovery mechanisms (i.e. fontconfig) are unsafe to reinit.
fn discover(self: *SharedGridSet) !?*Discover {
    // If we're built without a font discovery mechanism, return null
    if (comptime Discover == void) return null;

    // If we initialized, use it
    if (self.font_discover) |*v| return v;

    self.font_discover = .init();
    return &self.font_discover.?;
}

/// Ref-counted SharedGrid.
const ReffedGrid = struct {
    grid: *SharedGrid,
    ref: u32 = 0,
    missing: MissingFamilies = .{},
};

/// This is the configuration required to create a key without having
/// to keep the full Ghostty configuration around.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    @"font-family": configpkg.RepeatableString,
    @"font-family-bold": configpkg.RepeatableString,
    @"font-family-italic": configpkg.RepeatableString,
    @"font-family-bold-italic": configpkg.RepeatableString,
    @"font-style": configpkg.FontStyle,
    @"font-style-bold": configpkg.FontStyle,
    @"font-style-italic": configpkg.FontStyle,
    @"font-style-bold-italic": configpkg.FontStyle,
    @"font-variation": configpkg.RepeatableFontVariation,
    @"font-variation-bold": configpkg.RepeatableFontVariation,
    @"font-variation-italic": configpkg.RepeatableFontVariation,
    @"font-variation-bold-italic": configpkg.RepeatableFontVariation,
    @"font-codepoint-map": configpkg.RepeatableCodepointMap,
    @"font-synthetic-style": configpkg.FontSyntheticStyle,
    @"adjust-cell-width": ?Metrics.Modifier,
    @"adjust-cell-height": ?Metrics.Modifier,
    @"adjust-font-baseline": ?Metrics.Modifier,
    @"adjust-underline-position": ?Metrics.Modifier,
    @"adjust-underline-thickness": ?Metrics.Modifier,
    @"adjust-strikethrough-position": ?Metrics.Modifier,
    @"adjust-strikethrough-thickness": ?Metrics.Modifier,
    @"adjust-overline-position": ?Metrics.Modifier,
    @"adjust-overline-thickness": ?Metrics.Modifier,
    @"adjust-cursor-thickness": ?Metrics.Modifier,
    @"adjust-cursor-height": ?Metrics.Modifier,
    @"adjust-box-thickness": ?Metrics.Modifier,
    @"adjust-icon-height": ?Metrics.Modifier,
    @"freetype-load-flags": font.face.FreetypeLoadFlags,

    /// Initialize a DerivedConfig. The config should be either a
    /// config.Config or another DerivedConfig to clone from.
    pub fn init(
        alloc_gpa: Allocator,
        config: anytype,
    ) Allocator.Error!DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        return .{
            .@"font-family" = try config.@"font-family".clone(alloc),
            .@"font-family-bold" = try config.@"font-family-bold".clone(alloc),
            .@"font-family-italic" = try config.@"font-family-italic".clone(alloc),
            .@"font-family-bold-italic" = try config.@"font-family-bold-italic".clone(alloc),
            .@"font-style" = try config.@"font-style".clone(alloc),
            .@"font-style-bold" = try config.@"font-style-bold".clone(alloc),
            .@"font-style-italic" = try config.@"font-style-italic".clone(alloc),
            .@"font-style-bold-italic" = try config.@"font-style-bold-italic".clone(alloc),
            .@"font-variation" = try config.@"font-variation".clone(alloc),
            .@"font-variation-bold" = try config.@"font-variation-bold".clone(alloc),
            .@"font-variation-italic" = try config.@"font-variation-italic".clone(alloc),
            .@"font-variation-bold-italic" = try config.@"font-variation-bold-italic".clone(alloc),
            .@"font-codepoint-map" = try config.@"font-codepoint-map".clone(alloc),
            .@"font-synthetic-style" = config.@"font-synthetic-style",
            .@"adjust-cell-width" = config.@"adjust-cell-width",
            .@"adjust-cell-height" = config.@"adjust-cell-height",
            .@"adjust-font-baseline" = config.@"adjust-font-baseline",
            .@"adjust-underline-position" = config.@"adjust-underline-position",
            .@"adjust-underline-thickness" = config.@"adjust-underline-thickness",
            .@"adjust-strikethrough-position" = config.@"adjust-strikethrough-position",
            .@"adjust-strikethrough-thickness" = config.@"adjust-strikethrough-thickness",
            .@"adjust-overline-position" = config.@"adjust-overline-position",
            .@"adjust-overline-thickness" = config.@"adjust-overline-thickness",
            .@"adjust-cursor-thickness" = config.@"adjust-cursor-thickness",
            .@"adjust-cursor-height" = config.@"adjust-cursor-height",
            .@"adjust-box-thickness" = config.@"adjust-box-thickness",
            .@"adjust-icon-height" = config.@"adjust-icon-height",
            .@"freetype-load-flags" = if (font.face.FreetypeLoadFlags != void) config.@"freetype-load-flags" else {},

            // This must be last so the arena contains all our allocations
            // from above since Zig does assignment in order.
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// The key used to uniquely identify a font configuration.
pub const Key = struct {
    arena: ArenaAllocator,

    /// The descriptors used for all the fonts added to the
    /// initial group, including all styles. This is hashed
    /// in order so the order matters. All users of the struct
    /// should ensure that the order is consistent.
    descriptors: []const discovery.Descriptor = &.{},

    /// These are the offsets into the descriptors array for
    /// each style. For example, bold is from
    /// offsets[@intFromEnum(.bold) - 1] to
    /// offsets[@intFromEnum(.bold)].
    style_offsets: StyleOffsets = @splat(0),

    /// The codepoint map configuration.
    codepoint_map: CodepointMap = .{},

    /// The metric modifier set configuration.
    metric_modifiers: Metrics.ModifierSet = .{},

    /// The configured font size for this key. We don't use this
    /// directly but it is used as part of the hash for the
    /// font grid.
    font_size: DesiredSize = .{ .points = 12 },

    /// The freetype load flags configuration, only non-void if the
    /// freetype backend is enabled.
    freetype_load_flags: font.face.FreetypeLoadFlags = font.face.freetype_load_flags_default,

    const style_offsets_len = std.enums.directEnumArrayLen(Style, 0);
    const StyleOffsets = [style_offsets_len]usize;

    comptime {
        // We assume this throughout this structure. If this changes
        // we may need to change this structure.
        assert(@intFromEnum(Style.regular) == 0);
        assert(@intFromEnum(Style.bold) == 1);
        assert(@intFromEnum(Style.italic) == 2);
        assert(@intFromEnum(Style.bold_italic) == 3);
    }

    pub fn init(
        alloc_gpa: Allocator,
        config_src: *const DerivedConfig,
        font_size: DesiredSize,
    ) Allocator.Error!Key {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Clone our configuration. We need to do this because the lifetime
        // of the derived config is usually shorter than that of a key
        // and we use pointers into the derived config for the key. We
        // can remove this if we wanted by dupe-ing the memory we use
        // from DerivedConfig below.
        var config = try DerivedConfig.init(alloc, config_src);

        var descriptors: std.ArrayList(discovery.Descriptor) = .empty;
        defer descriptors.deinit(alloc);
        for (config.@"font-family".list.items) |family| {
            try descriptors.append(alloc, .{
                .family = family,
                .style = config.@"font-style".nameValue(),
                .size = font_size.points,
                .variations = config.@"font-variation".list.items,
            });
        }

        // In all the styled cases below, we prefer to specify an exact
        // style via the `font-style` configuration. If a style is not
        // specified, we use the discovery mechanism to search for a
        // style category such as bold, italic, etc. We can't specify both
        // because the latter will restrict the search to only that. If
        // a user says `font-style = italic` for the bold face for example,
        // no results would be found if we restrict to ALSO searching for
        // italic.
        for (config.@"font-family-bold".list.items) |family| {
            const style = config.@"font-style-bold".nameValue();
            try descriptors.append(alloc, .{
                .family = family,
                .style = style,
                .size = font_size.points,
                .bold = style == null,
                .variations = config.@"font-variation-bold".list.items,
            });
        }
        for (config.@"font-family-italic".list.items) |family| {
            const style = config.@"font-style-italic".nameValue();
            try descriptors.append(alloc, .{
                .family = family,
                .style = style,
                .size = font_size.points,
                .italic = style == null,
                .variations = config.@"font-variation-italic".list.items,
            });
        }
        for (config.@"font-family-bold-italic".list.items) |family| {
            const style = config.@"font-style-bold-italic".nameValue();
            try descriptors.append(alloc, .{
                .family = family,
                .style = style,
                .size = font_size.points,
                .bold = style == null,
                .italic = style == null,
                .variations = config.@"font-variation-bold-italic".list.items,
            });
        }

        // Setup the codepoint map
        const codepoint_map: CodepointMap = map: {
            const map = config.@"font-codepoint-map";
            if (map.map.list.len == 0) break :map .{};
            const clone = try config.@"font-codepoint-map".clone(alloc);
            break :map clone.map;
        };

        // Metric modifiers
        const metric_modifiers: Metrics.ModifierSet = set: {
            var set: Metrics.ModifierSet = .{};
            if (config.@"adjust-cell-width") |m| try set.put(alloc, .cell_width, m);
            if (config.@"adjust-cell-height") |m| try set.put(alloc, .cell_height, m);
            if (config.@"adjust-font-baseline") |m| try set.put(alloc, .cell_baseline, m);
            if (config.@"adjust-underline-position") |m| try set.put(alloc, .underline_position, m);
            if (config.@"adjust-underline-thickness") |m| try set.put(alloc, .underline_thickness, m);
            if (config.@"adjust-strikethrough-position") |m| try set.put(alloc, .strikethrough_position, m);
            if (config.@"adjust-strikethrough-thickness") |m| try set.put(alloc, .strikethrough_thickness, m);
            if (config.@"adjust-overline-position") |m| try set.put(alloc, .overline_position, m);
            if (config.@"adjust-overline-thickness") |m| try set.put(alloc, .overline_thickness, m);
            if (config.@"adjust-cursor-thickness") |m| try set.put(alloc, .cursor_thickness, m);
            if (config.@"adjust-cursor-height") |m| try set.put(alloc, .cursor_height, m);
            if (config.@"adjust-box-thickness") |m| try set.put(alloc, .box_thickness, m);
            if (config.@"adjust-icon-height") |m| try set.put(alloc, .icon_height, m);
            break :set set;
        };

        const regular_offset = config.@"font-family".list.items.len;
        const bold_offset = regular_offset + config.@"font-family-bold".list.items.len;
        const italic_offset = bold_offset + config.@"font-family-italic".list.items.len;
        const bold_italic_offset = italic_offset + config.@"font-family-bold-italic".list.items.len;

        return .{
            .arena = arena,
            .descriptors = try descriptors.toOwnedSlice(alloc),
            .style_offsets = .{
                regular_offset,
                bold_offset,
                italic_offset,
                bold_italic_offset,
            },
            .codepoint_map = codepoint_map,
            .metric_modifiers = metric_modifiers,
            .font_size = font_size,
            .freetype_load_flags = if (font.face.FreetypeLoadFlags != void)
                config.@"freetype-load-flags"
            else
                font.face.freetype_load_flags_default,
        };
    }

    pub fn deinit(self: *Key) void {
        self.arena.deinit();
    }

    /// Get the descriptors for the given font style that can be
    /// used with discovery.
    pub fn descriptorsForStyle(
        self: Key,
        style: Style,
    ) []const discovery.Descriptor {
        const idx = @intFromEnum(style);
        const start: usize = if (idx == 0) 0 else self.style_offsets[idx - 1];
        const end = self.style_offsets[idx];
        return self.descriptors[start..end];
    }

    /// Hash the key with the given hasher.
    pub fn hash(self: Key, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        autoHash(hasher, @as(u32, @bitCast(self.font_size.points)));
        autoHash(hasher, self.font_size.xdpi);
        autoHash(hasher, self.font_size.ydpi);
        autoHash(hasher, self.descriptors.len);
        for (self.descriptors) |d| d.hash(hasher);
        self.codepoint_map.hash(hasher);
        autoHash(hasher, self.metric_modifiers.count());
        autoHash(hasher, self.freetype_load_flags);
        if (self.metric_modifiers.count() > 0) {
            inline for (@typeInfo(Metrics.Key).@"enum".fields) |field| {
                const key = @field(Metrics.Key, field.name);
                if (self.metric_modifiers.get(key)) |value| {
                    autoHash(hasher, key);
                    value.hash(hasher);
                }
            }
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }
};

test "Key" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();

    var k = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k.deinit();

    var k2 = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k2.deinit();

    try testing.expect(k.hashcode() > 0);
    try testing.expectEqual(k.hashcode(), k2.hashcode());
}

test "Key different font points" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();

    var k = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k.deinit();

    var k2 = try Key.init(alloc, &keycfg, .{ .points = 16 });
    defer k2.deinit();

    try testing.expect(k.hashcode() != k2.hashcode());
}

test "Key different font DPI" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();

    var k = try Key.init(alloc, &keycfg, .{ .points = 12, .xdpi = 1 });
    defer k.deinit();

    var k2 = try Key.init(alloc, &keycfg, .{ .points = 12, .xdpi = 2 });
    defer k2.deinit();

    try testing.expect(k.hashcode() != k2.hashcode());
}

test SharedGridSet {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set = try SharedGridSet.init(alloc);
    defer set.deinit();

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();

    // Get a grid for the given config
    const key1, const grid1 = try set.ref(&keycfg, .{ .points = 12 });
    try testing.expectEqual(@as(usize, 1), set.count());

    // Get another
    const key2, const grid2 = try set.ref(&keycfg, .{ .points = 12 });
    try testing.expectEqual(@as(usize, 1), set.count());

    // They should be pointer equivalent
    try testing.expectEqual(@intFromPtr(grid1), @intFromPtr(grid2));

    // If I deref grid2 then we should still have a count of 1
    set.deref(key2);
    try testing.expectEqual(@as(usize, 1), set.count());

    // If I deref grid1 then we should have a count of 0
    set.deref(key1);
    try testing.expectEqual(@as(usize, 0), set.count());
}

test "SharedGridSet builds a grid that names no font without a font scan" {
    // F123: the default config names no font, so its grid needs nothing
    // from the system font scan and must neither wait for the startup
    // prefetch's scan nor run one. A fallback lookup scans when it needs to.
    if (comptime builtin.target.os.tag == .windows) {
        const testing = std.testing;
        const alloc = testing.allocator;

        var set = try SharedGridSet.init(alloc);
        defer set.deinit();
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var keycfg = try DerivedConfig.init(alloc, &cfg);
        defer keycfg.deinit();

        const key, _ = try set.ref(&keycfg, .{ .points = 12 });
        defer set.deref(key);
        try testing.expect(set.font_discover.?.state == null);
    } else return error.SkipZigTest;
}

test "SharedGridSet deinit stops the startup font scan at its next file" {
    // FLAKY-CLIFWD-CLOSE-01: closing the last window soon after launch
    // joined a scan that opens every installed font, so the windowless
    // process outlived its window by the rest of the scan (more than 20 s
    // on a cold hosted runner).
    if (comptime builtin.target.os.tag == .windows) {
        const testing = std.testing;

        // Four files the scan will try to open; the first is held open.
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        for ([_][]const u8{ "a.ttf", "b.ttf", "c.ttf", "d.ttf" }) |name| {
            try tmp.dir.writeFile(.{ .sub_path = name, .data = "" });
        }
        const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
        defer testing.allocator.free(dir);

        const Hold = struct {
            entered: std.Thread.ResetEvent = .{},
            calls: std.atomic.Value(usize) = .init(0),

            // A slow first open: it lasts until the scan is stopped, or
            // 5 s by the clock (a 1 ms sleep can take a 15.6 ms timer
            // tick), so a deinit that does not stop the scan fails
            // instead of hanging.
            fn call(ctx: *anyopaque, disco: *Discover, _: [:0]const u8) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                if (self.calls.fetchAdd(1, .monotonic) != 0) return;
                self.entered.set();
                var timer = std.time.Timer.start() catch return;
                while (!disco.scanStopped() and timer.read() < 5 * std.time.ns_per_s) {
                    std.Thread.sleep(std.time.ns_per_ms);
                }
            }
        };
        var hold: Hold = .{};

        var set = try SharedGridSet.init(testing.allocator);
        var set_live = true;
        defer if (set_live) set.deinit();
        const disco = (try set.discover()).?;
        if (disco.system_dir) |old| disco.alloc.free(old);
        disco.system_dir = try disco.alloc.dupeZ(u8, dir);
        if (disco.user_dir) |old| disco.alloc.free(old);
        disco.user_dir = null;
        disco.test_scan_hook = .{ .ctx = &hold, .call = Hold.call };

        set.startDiscoveryPrefetch();
        try testing.expect(set.discoveryPrefetchStarted());
        try hold.entered.timedWait(5 * std.time.ns_per_s);

        set_live = false;
        set.deinit();
        try testing.expectEqual(@as(usize, 1), hold.calls.load(.monotonic));
    } else return error.SkipZigTest;
}

test "MissingFamilies keeps each configured miss once across styles and skips the built-in font" {
    const testing = std.testing;
    var missing: MissingFamilies = .{};
    defer missing.deinit(testing.allocator);

    try missing.note(testing.allocator, "Pkg22 Mono");
    try missing.note(testing.allocator, "pkg22 mono");
    try missing.note(testing.allocator, "Second Mono");
    // A repeated family across styles is still one problem.
    try missing.note(testing.allocator, "Pkg22 Mono");
    try missing.note(testing.allocator, "Only In Italic");
    try missing.note(testing.allocator, "Only In Bold Italic");
    // The built-in font is what this family asks for.
    try missing.note(testing.allocator, "jetbrains mono");

    try testing.expectEqual(@as(usize, 4), missing.reportable().len);
    try testing.expectEqualStrings("Pkg22 Mono", missing.reportable()[0]);
    try testing.expectEqualStrings("Second Mono", missing.reportable()[1]);
    try testing.expectEqualStrings("Only In Italic", missing.reportable()[2]);
    try testing.expectEqualStrings("Only In Bold Italic", missing.reportable()[3]);
}

test "SharedGridSet reports missing fallback and styled families with a present regular family" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var set = try SharedGridSet.init(alloc);
    defer set.deinit();
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    const arena = cfg._arena.?.allocator();
    try cfg.@"font-family".parseCLI(arena, "Consolas");
    try cfg.@"font-family".parseCLI(arena, "Small05 Missing Fallback");
    try cfg.@"font-family-bold".parseCLI(arena, "Consolas");
    try cfg.@"font-family-bold".parseCLI(arena, "Small05 Missing Bold");
    try cfg.@"font-family-italic".parseCLI(arena, "Consolas");
    try cfg.@"font-family-italic".parseCLI(arena, "Small05 Missing Italic");
    try cfg.@"font-family-bold-italic".parseCLI(arena, "Consolas");
    try cfg.@"font-family-bold-italic".parseCLI(arena, "Small05 Missing Bold Italic");
    // The same missing name configured under another style is listed once.
    try cfg.@"font-family-bold-italic".parseCLI(arena, "small05 missing bold");
    var configured = try set.configuredMissingFamilies(alloc, &cfg);
    defer configured.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), set.count());
    try testing.expectEqual(@as(usize, 4), configured.reportable().len);
    try testing.expectEqualStrings("Small05 Missing Fallback", configured.reportable()[0]);
    try testing.expectEqualStrings("Small05 Missing Bold", configured.reportable()[1]);
    try testing.expectEqualStrings("Small05 Missing Italic", configured.reportable()[2]);
    try testing.expectEqualStrings("Small05 Missing Bold Italic", configured.reportable()[3]);
    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();
    const key, _ = try set.ref(&keycfg, .{ .points = 12 });
    defer set.deref(key);
    const missing = set.missingFamilies(key);
    try testing.expectEqual(@as(usize, 4), missing.len);
    try testing.expectEqualStrings("Small05 Missing Fallback", missing[0]);
    try testing.expectEqualStrings("Small05 Missing Bold", missing[1]);
    try testing.expectEqualStrings("Small05 Missing Italic", missing[2]);
    try testing.expectEqualStrings("Small05 Missing Bold Italic", missing[3]);
    const key2, _ = try set.ref(&keycfg, .{ .points = 12 });
    defer set.deref(key2);
    try testing.expectEqual(@as(usize, 4), set.missingFamilies(key2).len);
}

test "SharedGridSet does not call an installed family missing when its requested style is absent" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var set = try SharedGridSet.init(alloc);
    defer set.deinit();
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    const arena = cfg._arena.?.allocator();
    try cfg.@"font-family".parseCLI(arena, "Consolas");
    try cfg.@"font-style".parseCLI(arena, "Small05 Nonexistent Style");
    // Family-only checking must also accept a styled family's missing style.
    try cfg.@"font-family-bold".parseCLI(arena, "Consolas");
    try cfg.@"font-style-bold".parseCLI(arena, "Small05 Nonexistent Bold Style");
    var configured = try set.configuredMissingFamilies(alloc, &cfg);
    defer configured.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), configured.reportable().len);
    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();
    const key, _ = try set.ref(&keycfg, .{ .points = 12 });
    defer set.deref(key);
    try testing.expectEqual(@as(usize, 0), set.missingFamilies(key).len);
}

test "SharedGridSet checks unnamed and built-in families without a scan or a grid" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var set = try SharedGridSet.init(alloc);
    defer set.deinit();
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var unnamed = try set.configuredMissingFamilies(alloc, &cfg);
    defer unnamed.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), unnamed.reportable().len);
    try testing.expect(set.font_discover == null);

    const arena = cfg._arena.?.allocator();
    inline for (.{ "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic" }) |key| {
        try @field(cfg, key).parseCLI(arena, "jetbrains mono");
    }
    var embedded = try set.configuredMissingFamilies(alloc, &cfg);
    defer embedded.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), embedded.reportable().len);
    try testing.expect(set.font_discover == null);
    try testing.expectEqual(@as(usize, 0), set.count());
}

test "SharedGridSet reports a configured family that no installed font matches" {
    if (comptime builtin.target.os.tag == .windows) {
        const testing = std.testing;
        const alloc = testing.allocator;

        var set = try SharedGridSet.init(alloc);
        defer set.deinit();
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.@"font-family".parseCLI(cfg._arena.?.allocator(), "Pkg22 No Such Font");
        var keycfg = try DerivedConfig.init(alloc, &cfg);
        defer keycfg.deinit();

        const key, _ = try set.ref(&keycfg, .{ .points = 12 });
        defer set.deref(key);
        const missing = set.missingFamilies(key);
        try testing.expectEqual(@as(usize, 1), missing.len);
        try testing.expectEqualStrings("Pkg22 No Such Font", missing[0]);

        // A second reference to the same grid has the same answer and adds none.
        const key2, _ = try set.ref(&keycfg, .{ .points = 12 });
        defer set.deref(key2);
        try testing.expectEqual(@as(usize, 1), set.missingFamilies(key2).len);
    } else return error.SkipZigTest;
}

test "SharedGridSet reports no miss for the default font" {
    if (comptime builtin.target.os.tag == .windows) {
        const testing = std.testing;
        const alloc = testing.allocator;

        var set = try SharedGridSet.init(alloc);
        defer set.deinit();
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var keycfg = try DerivedConfig.init(alloc, &cfg);
        defer keycfg.deinit();

        const key, _ = try set.ref(&keycfg, .{ .points = 12 });
        defer set.deref(key);
        try testing.expectEqual(@as(usize, 0), set.missingFamilies(key).len);
    } else return error.SkipZigTest;
}
