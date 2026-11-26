const std = @import("std");
const translate_c = @import("translate_c");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("opengl", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    try translate_c.addImportToModule(b, "opengl_c", module, .{
        .source = .{ .includes = .{
            .files = &.{
                .{ .path = "glad/gl.h" },
                .{ .path = "glad/glad_egl.h" },
            },
        } },
        .target = target,
        .optimize = optimize,
        .include_paths = &.{b.path("../../vendor/glad/include")},
        // noctty: on Windows, EGL's platform header includes windows.h for
        // its native types, which Zig 0.17's translate-c (Aro) cannot parse
        // for the MSVC target. The fork draws through WGL and uses no EGL
        // native type, so those take Khronos's platform-neutral spelling.
        .extra_args = if (target.result.os.tag == .windows)
            &.{"-DEGL_NO_PLATFORM_SPECIFIC_TYPES"}
        else
            &.{},
    });
}
