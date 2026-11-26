const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const config_font = @import("../config/font_types.zig");
const options = @import("main.zig").options;
const freetype = @import("face/freetype.zig");
const coretext = struct {
    pub const Face = void;
};
pub const web_canvas = @import("face/web_canvas.zig");

/// Face implementation for the compile options.
pub const Face = switch (options.backend) {
    .freetype,
    .windows_freetype,
    .fontconfig_freetype,
    => freetype.Face,

    .web_canvas => web_canvas.Face,
};

/// If a DPI can't be calculated, this DPI is used. This is probably
/// wrong on modern devices so it is highly recommended you get the DPI
/// using whatever platform method you can.
pub const default_dpi = if (builtin.target.os.tag == .macos) 72 else 96;

/// These are the flags to customize how freetype loads fonts. This is
/// only non-void if the freetype backend is enabled.
pub const FreetypeLoadFlags = if (options.backend.hasFreetype())
    config_font.FreetypeLoadFlags
else
    void;
pub const freetype_load_flags_default: FreetypeLoadFlags = if (FreetypeLoadFlags != void) .{} else {};

/// Options for initializing a font face.
pub const Options = struct {
    size: DesiredSize,
    freetype_load_flags: FreetypeLoadFlags = freetype_load_flags_default,
};

/// The desired size for loading a font.
pub const DesiredSize = struct {
    // Desired size in points
    points: f32,

    // The DPI of the screen so we can convert points to pixels.
    xdpi: u16 = default_dpi,
    ydpi: u16 = default_dpi,

    // Converts points to pixels
    pub fn pixels(self: DesiredSize) f32 {
        // 1 point = 1/72 inch
        return (self.points * @as(f32, @floatFromInt(self.ydpi))) / 72;
    }

    /// GTK boxed types are not used in the Windows-only fork.
    pub const getGObjectType = void;
};

pub const Variation = @import("variation.zig").Variation;

test {
    @import("std").testing.refAllDecls(@This());
}

test "Variation.Id: wght should be 2003265652" {
    const testing = std.testing;
    const id = Variation.Id.init("wght");
    try testing.expectEqual(@as(u32, 2003265652), @as(u32, @bitCast(id)));
    try testing.expectEqualStrings("wght", &(id.str()));
}

test "Variation.Id: slnt should be 1936486004" {
    const testing = std.testing;
    const id: Variation.Id = .{ .a = 's', .b = 'l', .c = 'n', .d = 't' };
    try testing.expectEqual(@as(u32, 1936486004), @as(u32, @bitCast(id)));
    try testing.expectEqualStrings("slnt", &(id.str()));
}
