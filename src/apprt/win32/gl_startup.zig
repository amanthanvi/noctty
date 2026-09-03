//! Win32 OpenGL startup diagnostics.

const std = @import("std");
const builtin = @import("builtin");

const build_config = @import("../../build_config.zig");
const win32_types = @import("../win32_types.zig");
const c = @import("consts.zig");
const sys = @import("sys.zig");

const BOOL = win32_types.BOOL;
const DWORD = win32_types.DWORD;
const HMODULE = win32_types.HMODULE;
const HWND = win32_types.HWND;
const LPCWSTR = win32_types.LPCWSTR;
const UINT = win32_types.UINT;

const log = std.log.scoped(.win32);
const windows = std.os.windows;

pub var opengl32_module: HMODULE = null;

pub const StartupLoaderErrorDialogSuppression = struct {
    previous_mode: DWORD = 0,
    active: bool = false,

    pub fn restore(self: *StartupLoaderErrorDialogSuppression) void {
        if (!self.active) return;
        if (sys.SetThreadErrorMode(self.previous_mode, null) == 0) {
            log.warn(
                "failed to restore startup loader thread error mode win32_error={d}",
                .{@intFromEnum(windows.kernel32.GetLastError())},
            );
        }
        self.active = false;
    }
};

pub fn suppressStartupLoaderErrorDialogs() StartupLoaderErrorDialogSuppression {
    // Let WinMain report renderer startup failures with app-specific guidance
    // instead of letting LoadLibrary/WGL surface generic Windows dialogs first.
    var previous_mode: DWORD = 0;
    if (sys.SetThreadErrorMode(c.SEM_FAILCRITICALERRORS | c.SEM_NOOPENFILEERRORBOX, &previous_mode) == 0) {
        log.warn(
            "failed to suppress startup loader error dialogs win32_error={d}",
            .{@intFromEnum(windows.kernel32.GetLastError())},
        );
        return .{};
    }
    return .{ .previous_mode = previous_mode, .active = true };
}

pub const OpenGLStartupStep = enum {
    get_dc,
    choose_pixel_format,
    describe_pixel_format,
    set_pixel_format,
    create_context,
    initial_make_current,
    load_opengl32,
    make_current,
    load_functions,
    version_check,
    framebuffer_srgb,

    fn label(self: OpenGLStartupStep) []const u8 {
        return switch (self) {
            .get_dc => "acquiring the window device context",
            .choose_pixel_format => "choosing a WGL pixel format",
            .describe_pixel_format => "describing the selected WGL pixel format",
            .set_pixel_format => "setting the WGL pixel format",
            .create_context => "creating the WGL context",
            .initial_make_current => "making the initial WGL context current",
            .load_opengl32 => "loading opengl32.dll",
            .make_current => "making the WGL context current",
            .load_functions => "loading OpenGL functions",
            .version_check => "checking the OpenGL version",
            .framebuffer_srgb => "enabling OpenGL sRGB framebuffer support",
        };
    }
};

const OpenGLStartupFailure = struct {
    step: OpenGLStartupStep,
    win32_error: ?DWORD = null,
    zig_error_name: ?[]const u8 = null,
    detected: ?DetectedOpenGL = null,
};

/// Fixed-capacity copy of a driver-reported string (`GL_RENDERER`,
/// `GL_VENDOR`). The failure path stays allocation-free, and `capacity` is
/// the single bound the renderer uses when it scans the driver string.
pub const OpenGLStartupString = struct {
    pub const capacity = 128;

    bytes: [capacity]u8 = undefined,
    len: u8 = 0,

    fn init(driver_text: ?[]const u8) OpenGLStartupString {
        var result: OpenGLStartupString = .{};
        const source = driver_text orelse return result;
        const len = @min(source.len, capacity);
        @memcpy(result.bytes[0..len], source[0..len]);
        result.len = @intCast(len);
        return result;
    }

    fn value(self: *const OpenGLStartupString) []const u8 {
        return self.bytes[0..self.len];
    }
};

const DetectedOpenGL = struct {
    major: u32,
    minor: u32,
    renderer: OpenGLStartupString = .{},
    vendor: OpenGLStartupString = .{},
};

var opengl_startup_diagnostics_mutex: std.Thread.Mutex = .{};
var opengl_startup_diagnostics_active = false;
var last_opengl_startup_failure: ?OpenGLStartupFailure = null;

pub fn beginOpenGLStartupDiagnostics() void {
    opengl_startup_diagnostics_mutex.lock();
    defer opengl_startup_diagnostics_mutex.unlock();

    opengl_startup_diagnostics_active = true;
    last_opengl_startup_failure = null;
}

pub fn clearOpenGLStartupFailure() void {
    opengl_startup_diagnostics_mutex.lock();
    defer opengl_startup_diagnostics_mutex.unlock();

    opengl_startup_diagnostics_active = false;
    last_opengl_startup_failure = null;
}

fn recordOpenGLStartupFailure(failure: OpenGLStartupFailure) bool {
    opengl_startup_diagnostics_mutex.lock();
    defer opengl_startup_diagnostics_mutex.unlock();

    if (!opengl_startup_diagnostics_active) return false;
    if (last_opengl_startup_failure) |previous| {
        if (previous.win32_error != null and failure.win32_error == null) return false;
    }

    last_opengl_startup_failure = failure;
    return true;
}

fn openGLStartupDiagnosticsActive() bool {
    opengl_startup_diagnostics_mutex.lock();
    defer opengl_startup_diagnostics_mutex.unlock();

    return opengl_startup_diagnostics_active;
}

fn currentOpenGLStartupFailure() ?OpenGLStartupFailure {
    opengl_startup_diagnostics_mutex.lock();
    defer opengl_startup_diagnostics_mutex.unlock();

    return last_opengl_startup_failure;
}

pub fn recordOpenGLStartupWin32Failure(step: OpenGLStartupStep, win32_error: windows.Win32Error) void {
    const code: DWORD = @intFromEnum(win32_error);
    if (!recordOpenGLStartupFailure(.{
        .step = step,
        .win32_error = code,
    })) return;

    log.err(
        "Win32 OpenGL startup failed step={s} win32_error={d}",
        .{ step.label(), code },
    );
}

pub fn recordOpenGLStartupError(step: OpenGLStartupStep, err: anyerror) void {
    if (!recordOpenGLStartupFailure(.{
        .step = step,
        .zig_error_name = @errorName(err),
    })) return;

    log.err("Win32 OpenGL startup failed step={s} error={s}", .{ step.label(), @errorName(err) });
}

/// Record a below-floor version check together with what the machine
/// actually reported, so the dialog can say "required 4.3, detected 1.1"
/// instead of only naming the requirement.
pub fn recordOpenGLStartupVersionError(
    major: u32,
    minor: u32,
    renderer: ?[]const u8,
    vendor: ?[]const u8,
) void {
    if (!recordOpenGLStartupFailure(.{
        .step = .version_check,
        .zig_error_name = @errorName(error.OpenGLOutdated),
        .detected = .{
            .major = major,
            .minor = minor,
            .renderer = .init(renderer),
            .vendor = .init(vendor),
        },
    })) return;

    log.err(
        "Win32 OpenGL startup version check failed required=4.3 detected={d}.{d} renderer={s} vendor={s}",
        .{ major, minor, renderer orelse "not reported", vendor orelse "not reported" },
    );
}

pub fn reportStartupFailure(err: anyerror) void {
    if (comptime builtin.os.tag != .windows) return;

    var buf: [4096]u8 = undefined;
    const message = formatStartupFailureMessage(&buf, err);

    const caption = std.unicode.utf8ToUtf16LeStringLiteral("noctty failed");
    const fallback = std.unicode.utf8ToUtf16LeStringLiteral("noctty failed.");

    const message_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, message) catch {
        _ = sys.MessageBoxW(null, fallback, caption, c.MB_OK | c.MB_ICONERROR | c.MB_SETFOREGROUND);
        return;
    };
    defer std.heap.page_allocator.free(message_w);

    _ = sys.MessageBoxW(null, message_w, caption, c.MB_OK | c.MB_ICONERROR | c.MB_SETFOREGROUND);
}

fn formatStartupFailureMessage(buf: []u8, err: anyerror) []const u8 {
    if (currentOpenGLStartupFailure()) |failure| {
        return formatOpenGLStartupFailureMessage(buf, err, failure) catch
            "noctty could not initialize the Windows OpenGL renderer.";
    }

    return std.fmt.bufPrint(
        buf,
        "noctty {s} failed: {s}\n\nOpen an issue with the full log if this keeps happening.",
        .{ build_config.version_string, @errorName(err) },
    ) catch "noctty failed.";
}

fn formatOpenGLStartupFailureMessage(buf: []u8, err: anyerror, failure: OpenGLStartupFailure) ![]const u8 {
    const zig_error_name = failure.zig_error_name orelse @errorName(err);

    if (failure.detected) |detected| {
        var win32_error_buf: [64]u8 = undefined;
        const win32_error_text = if (failure.win32_error) |win32_error|
            try std.fmt.bufPrint(&win32_error_buf, "{d}{s}", .{ win32_error, win32ErrorSuffix(win32_error) })
        else
            "not reported";

        return std.fmt.bufPrint(buf,
            \\noctty {s} could not initialize the Windows OpenGL renderer while {s}.
            \\
            \\Startup error: {s}
            \\Win32 error: {s}
            \\Required OpenGL version: 4.3 through WGL
            \\Detected OpenGL version: {d}.{d}
            \\Detected renderer: {s}
            \\Detected vendor: {s}
            \\
            \\This build does not include a software, DirectX, or ANGLE fallback renderer, so noctty cannot start below OpenGL 4.3.
            \\
            \\Try ending Remote Desktop and launching noctty in a local console session; enabling 3D acceleration and installing the VM guest graphics driver; or updating or reinstalling your GPU driver. On hybrid-GPU systems, you can also force noctty.exe to the discrete or integrated GPU in Windows Graphics settings.
            \\
            \\If it still fails, attach this text and the log to https://github.com/amanthanvi/noctty/issues/64.
        , .{
            build_config.version_string,
            failure.step.label(),
            zig_error_name,
            win32_error_text,
            detected.major,
            detected.minor,
            if (detected.renderer.len > 0) detected.renderer.value() else "not reported",
            if (detected.vendor.len > 0) detected.vendor.value() else "not reported",
        });
    }

    if (failure.win32_error) |win32_error| {
        return std.fmt.bufPrint(buf,
            \\noctty {s} could not initialize the Windows OpenGL renderer while {s}.
            \\
            \\Startup error: {s}
            \\Win32 error: {d}{s}
            \\
            \\noctty currently uses OpenGL 4.3 through WGL on Windows. This build does not include a DirectX or ANGLE fallback renderer.
            \\
            \\{s}
            \\
            \\Try updating or reinstalling the OEM AMD graphics driver, then the NVIDIA driver. You can also force noctty.exe to the discrete or integrated GPU in Windows Graphics settings. If it still fails, attach this text and the log to https://github.com/amanthanvi/noctty/issues/64.
        , .{
            build_config.version_string,
            failure.step.label(),
            zig_error_name,
            win32_error,
            win32ErrorSuffix(win32_error),
            openglStartupFailureHint(failure),
        });
    }

    return std.fmt.bufPrint(buf,
        \\noctty {s} could not initialize the Windows OpenGL renderer while {s}.
        \\
        \\Startup error: {s}
        \\Win32 error: not reported
        \\
        \\noctty currently uses OpenGL 4.3 through WGL on Windows. This build does not include a DirectX or ANGLE fallback renderer.
        \\
        \\{s}
        \\
        \\Try updating or reinstalling the OEM AMD graphics driver, then the NVIDIA driver. You can also force noctty.exe to the discrete or integrated GPU in Windows Graphics settings. If it still fails, attach this text and the log to https://github.com/amanthanvi/noctty/issues/64.
    , .{
        build_config.version_string,
        failure.step.label(),
        zig_error_name,
        openglStartupFailureHint(failure),
    });
}

fn win32ErrorSuffix(code: DWORD) []const u8 {
    return switch (code) {
        c.ERROR_MOD_NOT_FOUND => " (ERROR_MOD_NOT_FOUND)",
        else => "",
    };
}

fn openglStartupFailureHint(failure: OpenGLStartupFailure) []const u8 {
    if (failure.win32_error) |code| {
        if (code == c.ERROR_MOD_NOT_FOUND) {
            return "Win32 error 126 means Windows could not load a graphics-driver DLL or one of its dependent DLLs. On AMD+NVIDIA hybrid GPU laptops, this can happen while WGL loads the AMD OpenGL ICD from DriverStore.";
        }
    }

    if (failure.step == .version_check) {
        return "The active GPU driver did not expose the required OpenGL 4.3 feature level.";
    }

    return "This is usually caused by an unavailable or incompatible OpenGL driver, a stale GPU driver installation, or missing OpenGL 4.3 support.";
}

test "win32-opengl-startup-failure-message-explains-error-126" {
    var buf: [4096]u8 = undefined;
    const message = try formatOpenGLStartupFailureMessage(&buf, error.Unexpected, .{
        .step = .create_context,
        .win32_error = c.ERROR_MOD_NOT_FOUND,
        .zig_error_name = "Unexpected",
    });

    try std.testing.expect(std.mem.indexOf(u8, message, "Win32 error: 126 (ERROR_MOD_NOT_FOUND)") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "AMD+NVIDIA hybrid GPU") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "DirectX or ANGLE fallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "https://github.com/amanthanvi/noctty/issues/64") != null);
}

test "win32-opengl-startup-failure-message-explains-version-floor" {
    var buf: [4096]u8 = undefined;
    const message = try formatOpenGLStartupFailureMessage(&buf, error.OpenGLOutdated, .{
        .step = .version_check,
        .zig_error_name = "OpenGLOutdated",
    });

    try std.testing.expect(std.mem.indexOf(u8, message, "OpenGL 4.3 through WGL") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "required OpenGL 4.3 feature level") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Win32 error: not reported") != null);
}

test "win32-opengl-startup-failure-message-reports-detected-version" {
    var buf: [4096]u8 = undefined;
    const message = try formatOpenGLStartupFailureMessage(&buf, error.OpenGLOutdated, .{
        .step = .version_check,
        .zig_error_name = "OpenGLOutdated",
        .detected = .{
            .major = 1,
            .minor = 1,
            .renderer = .init("GDI Generic"),
            .vendor = .init("Microsoft Corporation"),
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, message, "while checking the OpenGL version") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Required OpenGL version: 4.3 through WGL") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Detected OpenGL version: 1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Detected renderer: GDI Generic") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Detected vendor: Microsoft Corporation") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Win32 error: not reported") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "noctty cannot start below OpenGL 4.3") != null);
}

// The step label and Win32 error come from the record, not from literal
// text, so a future caller recording a detected payload for another step
// gets the right wording.
test "win32-opengl-startup-detected-version-message-uses-recorded-diagnostics" {
    var buf: [4096]u8 = undefined;
    const message = try formatOpenGLStartupFailureMessage(&buf, error.OpenGLOutdated, .{
        .step = .create_context,
        .win32_error = c.ERROR_MOD_NOT_FOUND,
        .zig_error_name = "OpenGLOutdated",
        .detected = .{ .major = 1, .minor = 1 },
    });

    try std.testing.expect(std.mem.indexOf(u8, message, "while creating the WGL context") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "while checking the OpenGL version") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Win32 error: 126 (ERROR_MOD_NOT_FOUND)") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Detected renderer: not reported") != null);
}

test "win32-opengl-startup-failure-bounds-driver-strings" {
    const value = "x" ** (OpenGLStartupString.capacity + 1);
    const captured = OpenGLStartupString.init(value);

    try std.testing.expectEqual(OpenGLStartupString.capacity, captured.value().len);
    try std.testing.expectEqualStrings(value[0..OpenGLStartupString.capacity], captured.value());
    try std.testing.expectEqual(@as(usize, 0), OpenGLStartupString.init(null).value().len);
}

test "win32-opengl-startup-failure-recording-is-startup-scoped" {
    clearOpenGLStartupFailure();
    recordOpenGLStartupError(.make_current, error.Unexpected);
    try std.testing.expect(currentOpenGLStartupFailure() == null);

    beginOpenGLStartupDiagnostics();
    try std.testing.expect(openGLStartupDiagnosticsActive());

    clearOpenGLStartupFailure();
    try std.testing.expect(!openGLStartupDiagnosticsActive());
    try std.testing.expect(currentOpenGLStartupFailure() == null);
}

test "win32-opengl-startup-failure-preserves-win32-loader-cause" {
    clearOpenGLStartupFailure();
    beginOpenGLStartupDiagnostics();

    try std.testing.expect(recordOpenGLStartupFailure(.{
        .step = .load_opengl32,
        .win32_error = c.ERROR_MOD_NOT_FOUND,
    }));
    try std.testing.expect(!recordOpenGLStartupFailure(.{
        .step = .load_functions,
        .zig_error_name = "OpenGLFunctionLoadFailed",
    }));

    const failure = currentOpenGLStartupFailure().?;
    try std.testing.expectEqual(OpenGLStartupStep.load_opengl32, failure.step);
    try std.testing.expectEqual(@as(?DWORD, c.ERROR_MOD_NOT_FOUND), failure.win32_error);

    clearOpenGLStartupFailure();
}
