//! Win32 OpenGL startup diagnostics.

const std = @import("std");
const builtin = @import("builtin");

const build_config = @import("../../build_config.zig");
const os_windows = @import("../../os/windows.zig");
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

/// Remove the current directory and inherited PATH from bare-name DLL
/// resolution before process initialization can trigger any dynamic loads.
/// The caller captures and logs a failure only after global logging is ready.
pub fn setDefaultDllDirectories() ?windows.Win32Error {
    if (sys.SetDefaultDllDirectories(c.LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) != 0) {
        return null;
    }
    return windows.kernel32.GetLastError();
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
        return formatOpenGLStartupFailureMessage(
            buf,
            err,
            failure,
            os_windows.detectProcessArchitecture(),
        ) catch
            "noctty could not initialize the Windows OpenGL renderer.";
    }

    return std.fmt.bufPrint(
        buf,
        "noctty {s} failed: {s}\n\nOpen an issue with the full log if this keeps happening.",
        .{ build_config.version_string, @errorName(err) },
    ) catch "noctty failed.";
}

/// Where a working OpenGL 4.3 implementation is supposed to come from on this
/// machine, which decides what the dialog tells the user to install.
///
/// Windows on ARM has no vendor desktop-OpenGL ICD: Qualcomm ships none, so a
/// Snapdragon PC has no AMD or NVIDIA driver to reinstall and no second GPU to
/// select in Windows Graphics settings. Its OpenGL comes from Microsoft's
/// Direct3D 12 mapping layer instead, which ships in a Microsoft Store pack
/// the user has to install. Naming the wrong source sends an ARM64 bug
/// reporter chasing drivers that cannot exist.
const Remediation = enum {
    /// Windows on ARM, where the Microsoft mapping layer is the only source.
    arm64,
    /// x86/x64, where a GPU vendor's installable client driver is the source.
    vendor_icd,

    fn forNativeMachine(native_machine: u16) Remediation {
        return if (native_machine == os_windows.IMAGE_FILE_MACHINE_ARM64)
            .arm64
        else
            .vendor_icd;
    }
};

/// The machine noctty is running on, falling back to the build target when
/// Windows reported nothing usable.
///
/// The fallback is safe in the direction that matters: an ARM64 binary only
/// ever runs on ARM64 Windows, so it cannot mistake a Snapdragon for an x64
/// desktop and hand back driver advice that names hardware it does not have.
fn nativeMachineOrBuild(arch: ?os_windows.ProcessArchitecture) u16 {
    const detected = arch orelse return os_windows.build_machine;
    if (detected.native_machine == os_windows.IMAGE_FILE_MACHINE_UNKNOWN) {
        return os_windows.build_machine;
    }
    return detected.native_machine;
}

/// Advice for the version-floor dialog, which already carries its own Remote
/// Desktop and VM guidance.
fn detectedRemediationAdvice(remediation: Remediation) []const u8 {
    return switch (remediation) {
        .arm64 =>
        \\This is a Windows on ARM PC, and Qualcomm Snapdragon systems ship no desktop OpenGL driver at all. A detected renderer of "GDI Generic" at version 1.1 means none is installed: get the free "OpenCL, OpenGL, and Vulkan Compatibility Pack" from the Microsoft Store and restart noctty. It supplies a desktop OpenGL implementation that runs on Direct3D 12.
        \\
        \\If that pack is already installed and the detected version above is still below 4.3, it is not exposing enough OpenGL on this GPU and noctty cannot start on it. Microsoft's support statement for the pack promises only OpenGL 3.3, so a version between 3.3 and 4.3 is the pack working as documented rather than a broken install.
        \\
        \\If you are on Remote Desktop, end the session and launch noctty in a local console session. In a VM, enable 3D acceleration and install the guest graphics driver.
        ,
        .vendor_icd => "Try ending Remote Desktop and launching noctty in a local console session; enabling 3D acceleration and installing the VM guest graphics driver; or updating or reinstalling your GPU driver. On hybrid-GPU systems, you can also force noctty.exe to the discrete or integrated GPU in Windows Graphics settings.",
    };
}

/// Advice for the two dialogs that report a failed initialization step rather
/// than a detected version.
fn stepRemediationAdvice(remediation: Remediation) []const u8 {
    return switch (remediation) {
        .arm64 => "This is a Windows on ARM PC, and Qualcomm Snapdragon systems ship no desktop OpenGL driver at all. Install the free \"OpenCL, OpenGL, and Vulkan Compatibility Pack\" from the Microsoft Store and restart noctty: it is the only way to get a desktop OpenGL implementation here, and it supplies one that runs on Direct3D 12. If it still fails, attach this text and the log to https://github.com/amanthanvi/noctty/issues/64.",
        .vendor_icd => "Try updating or reinstalling the OEM AMD graphics driver, then the NVIDIA driver. You can also force noctty.exe to the discrete or integrated GPU in Windows Graphics settings. If it still fails, attach this text and the log to https://github.com/amanthanvi/noctty/issues/64.",
    };
}

/// One line of architecture provenance for the dialog, so a bug report
/// separates a native ARM64 build from an x64 build under emulation without
/// the reporter having to know how to check.
fn formatArchitectureLine(buf: []u8, arch: ?os_windows.ProcessArchitecture) []const u8 {
    var native_buf: [24]u8 = undefined;
    var process_buf: [24]u8 = undefined;

    if (arch) |detected| {
        if (detected.native_machine != os_windows.IMAGE_FILE_MACHINE_UNKNOWN) {
            const native = os_windows.machineArchitectureLabel(
                &native_buf,
                detected.native_machine,
            );
            const process = os_windows.machineArchitectureLabel(
                &process_buf,
                detected.process_machine,
            );
            if (std.fmt.bufPrint(buf, "{s} process on {s} Windows{s}", .{
                process,
                native,
                if (detected.emulated()) " (emulated)" else "",
            })) |line| return line else |_| {}
        }
    }

    // Windows told us nothing usable, so fall back to the one architecture
    // fact that is always available: what this binary was built for.
    return std.fmt.bufPrint(
        buf,
        "{s} build; Windows did not report the process architecture",
        .{os_windows.machineArchitectureLabel(&native_buf, os_windows.build_machine)},
    ) catch "not reported";
}

fn formatOpenGLStartupFailureMessage(
    buf: []u8,
    err: anyerror,
    failure: OpenGLStartupFailure,
    arch: ?os_windows.ProcessArchitecture,
) ![]const u8 {
    const zig_error_name = failure.zig_error_name orelse @errorName(err);
    const remediation: Remediation = .forNativeMachine(nativeMachineOrBuild(arch));

    var architecture_buf: [96]u8 = undefined;
    const architecture_text = formatArchitectureLine(&architecture_buf, arch);

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
            \\Architecture: {s}
            \\Required OpenGL version: 4.3 through WGL
            \\Detected OpenGL version: {d}.{d}
            \\Detected renderer: {s}
            \\Detected vendor: {s}
            \\
            \\This build does not include a software, DirectX, or ANGLE fallback renderer, so noctty cannot start below OpenGL 4.3.
            \\
            \\{s}
            \\
            \\If it still fails, attach this text and the log to https://github.com/amanthanvi/noctty/issues/64.
        , .{
            build_config.version_string,
            failure.step.label(),
            zig_error_name,
            win32_error_text,
            architecture_text,
            detected.major,
            detected.minor,
            if (detected.renderer.len > 0) detected.renderer.value() else "not reported",
            if (detected.vendor.len > 0) detected.vendor.value() else "not reported",
            detectedRemediationAdvice(remediation),
        });
    }

    if (failure.win32_error) |win32_error| {
        return std.fmt.bufPrint(buf,
            \\noctty {s} could not initialize the Windows OpenGL renderer while {s}.
            \\
            \\Startup error: {s}
            \\Win32 error: {d}{s}
            \\Architecture: {s}
            \\
            \\noctty currently uses OpenGL 4.3 through WGL on Windows. This build does not include a DirectX or ANGLE fallback renderer.
            \\
            \\{s}
            \\
            \\{s}
        , .{
            build_config.version_string,
            failure.step.label(),
            zig_error_name,
            win32_error,
            win32ErrorSuffix(win32_error),
            architecture_text,
            openglStartupFailureHint(failure, remediation),
            stepRemediationAdvice(remediation),
        });
    }

    return std.fmt.bufPrint(buf,
        \\noctty {s} could not initialize the Windows OpenGL renderer while {s}.
        \\
        \\Startup error: {s}
        \\Win32 error: not reported
        \\Architecture: {s}
        \\
        \\noctty currently uses OpenGL 4.3 through WGL on Windows. This build does not include a DirectX or ANGLE fallback renderer.
        \\
        \\{s}
        \\
        \\{s}
    , .{
        build_config.version_string,
        failure.step.label(),
        zig_error_name,
        architecture_text,
        openglStartupFailureHint(failure, remediation),
        stepRemediationAdvice(remediation),
    });
}

fn win32ErrorSuffix(code: DWORD) []const u8 {
    return switch (code) {
        c.ERROR_MOD_NOT_FOUND => " (ERROR_MOD_NOT_FOUND)",
        else => "",
    };
}

fn openglStartupFailureHint(failure: OpenGLStartupFailure, remediation: Remediation) []const u8 {
    if (failure.win32_error) |code| {
        if (code == c.ERROR_MOD_NOT_FOUND) {
            return switch (remediation) {
                .arm64 => "Win32 error 126 means Windows could not load a graphics-driver DLL or one of its dependent DLLs. On Windows on ARM that usually means no OpenGL implementation is installed at all, because Qualcomm ships no desktop OpenGL driver.",
                .vendor_icd => "Win32 error 126 means Windows could not load a graphics-driver DLL or one of its dependent DLLs. On AMD+NVIDIA hybrid GPU laptops, this can happen while WGL loads the AMD OpenGL ICD from DriverStore.",
            };
        }
    }

    if (failure.step == .version_check) {
        return switch (remediation) {
            .arm64 => "No installed OpenGL implementation exposed the required OpenGL 4.3 feature level.",
            .vendor_icd => "The active GPU driver did not expose the required OpenGL 4.3 feature level.",
        };
    }

    return switch (remediation) {
        .arm64 => "This is usually caused by a missing or incompatible OpenGL implementation, or by one that does not reach OpenGL 4.3.",
        .vendor_icd => "This is usually caused by an unavailable or incompatible OpenGL driver, a stale GPU driver installation, or missing OpenGL 4.3 support.",
    };
}

// These are resolved architectures, as `os_windows.resolveProcessArchitecture`
// hands them to this module: the process machine is always concrete, so these
// fixtures do not change meaning with the architecture the suite is built for.

/// A native x64 desktop, where the existing GPU-vendor advice is correct.
const test_x64: os_windows.ProcessArchitecture = .{
    .process_machine = os_windows.IMAGE_FILE_MACHINE_AMD64,
    .native_machine = os_windows.IMAGE_FILE_MACHINE_AMD64,
};

/// A native ARM64 build on a Snapdragon PC, as in issue #255.
const test_arm64: os_windows.ProcessArchitecture = .{
    .process_machine = os_windows.IMAGE_FILE_MACHINE_ARM64,
    .native_machine = os_windows.IMAGE_FILE_MACHINE_ARM64,
};

/// An x64 build running under Windows on ARM emulation.
const test_x64_on_arm64: os_windows.ProcessArchitecture = .{
    .process_machine = os_windows.IMAGE_FILE_MACHINE_AMD64,
    .native_machine = os_windows.IMAGE_FILE_MACHINE_ARM64,
};

/// Every dialog path must be free of advice that names hardware a Snapdragon
/// PC does not have.
fn expectNoVendorGpuAdvice(message: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, message, "AMD") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "NVIDIA") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Windows Graphics settings") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "discrete or integrated GPU") == null);
}

test "win32-opengl-startup-failure-message-explains-error-126" {
    var buf: [4096]u8 = undefined;
    const message = try formatOpenGLStartupFailureMessage(&buf, error.Unexpected, .{
        .step = .create_context,
        .win32_error = c.ERROR_MOD_NOT_FOUND,
        .zig_error_name = "Unexpected",
    }, test_x64);

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
    }, test_x64);

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
    }, test_x64);

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
    }, test_x64);

    try std.testing.expect(std.mem.indexOf(u8, message, "while creating the WGL context") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "while checking the OpenGL version") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Win32 error: 126 (ERROR_MOD_NOT_FOUND)") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Detected renderer: not reported") != null);
}

test "win32-opengl-startup-remediation-follows-the-native-machine" {
    try std.testing.expectEqual(
        Remediation.arm64,
        Remediation.forNativeMachine(os_windows.IMAGE_FILE_MACHINE_ARM64),
    );
    try std.testing.expectEqual(
        Remediation.vendor_icd,
        Remediation.forNativeMachine(os_windows.IMAGE_FILE_MACHINE_AMD64),
    );
    try std.testing.expectEqual(
        Remediation.vendor_icd,
        Remediation.forNativeMachine(os_windows.IMAGE_FILE_MACHINE_I386),
    );
    // ARM32 is not Windows on ARM64 and has no Compatibility Pack.
    try std.testing.expectEqual(
        Remediation.vendor_icd,
        Remediation.forNativeMachine(os_windows.IMAGE_FILE_MACHINE_ARMNT),
    );

    // An x64 build under emulation still needs the ARM advice: the machine,
    // not the process, decides which drivers can exist.
    try std.testing.expectEqual(
        os_windows.IMAGE_FILE_MACHINE_ARM64,
        nativeMachineOrBuild(test_x64_on_arm64),
    );
    try std.testing.expectEqual(
        os_windows.IMAGE_FILE_MACHINE_AMD64,
        nativeMachineOrBuild(test_x64),
    );

    // Anything Windows did not report falls back to the build target, so an
    // ARM64 build can never be handed x64 driver advice.
    try std.testing.expectEqual(os_windows.build_machine, nativeMachineOrBuild(null));
    try std.testing.expectEqual(os_windows.build_machine, nativeMachineOrBuild(.{
        .process_machine = os_windows.build_machine,
        .native_machine = os_windows.IMAGE_FILE_MACHINE_UNKNOWN,
    }));
}

test "win32-opengl-startup-architecture-line-separates-native-from-emulated" {
    var buf: [96]u8 = undefined;

    try std.testing.expectEqualStrings(
        "ARM64 process on ARM64 Windows",
        formatArchitectureLine(&buf, test_arm64),
    );
    try std.testing.expectEqualStrings(
        "x64 process on x64 Windows",
        formatArchitectureLine(&buf, test_x64),
    );
    // The case the line exists for: Windows on ARM reports the same process
    // machine for this as for a native ARM64 process, so the line must not
    // claim "ARM64 process" here.
    try std.testing.expectEqualStrings(
        "x64 process on ARM64 Windows (emulated)",
        formatArchitectureLine(&buf, test_x64_on_arm64),
    );

    // With no usable report, the build target is still stated, and a native
    // process is never described to the user as "unknown".
    var build_buf: [24]u8 = undefined;
    const build_name = os_windows.machineArchitectureLabel(&build_buf, os_windows.build_machine);

    var unreported_buf: [96]u8 = undefined;
    const unreported = formatArchitectureLine(&unreported_buf, null);
    try std.testing.expect(std.mem.startsWith(u8, unreported, build_name));
    try std.testing.expect(std.mem.indexOf(u8, unreported, "did not report") != null);
    try std.testing.expect(std.mem.indexOf(u8, unreported, "unknown") == null);

    // A separate buffer, so this compares two independently rendered strings
    // rather than one buffer against itself.
    try std.testing.expectEqualStrings(unreported, formatArchitectureLine(&buf, .{
        .process_machine = os_windows.build_machine,
        .native_machine = os_windows.IMAGE_FILE_MACHINE_UNKNOWN,
    }));
}

test "win32-opengl-startup-arm64-message-names-the-compatibility-pack" {
    var buf: [4096]u8 = undefined;

    // Path 1: the detected-version dialog, which is what issue #255 hit.
    const detected_message = try formatOpenGLStartupFailureMessage(&buf, error.OpenGLOutdated, .{
        .step = .version_check,
        .zig_error_name = "OpenGLOutdated",
        .detected = .{
            .major = 1,
            .minor = 1,
            .renderer = .init("GDI Generic"),
            .vendor = .init("Microsoft Corporation"),
        },
    }, test_arm64);

    try std.testing.expect(std.mem.indexOf(u8, detected_message, "Architecture: ARM64 process on ARM64 Windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, detected_message, "OpenCL, OpenGL, and Vulkan Compatibility Pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, detected_message, "Microsoft Store") != null);
    try std.testing.expect(std.mem.indexOf(u8, detected_message, "Detected renderer: GDI Generic") != null);
    // Remote Desktop and VM guidance is architecture-neutral and stays.
    try std.testing.expect(std.mem.indexOf(u8, detected_message, "Remote Desktop") != null);
    try std.testing.expect(std.mem.indexOf(u8, detected_message, "3D acceleration") != null);
    try expectNoVendorGpuAdvice(detected_message);

    // Path 2: a Win32 error with no detected version.
    var win32_buf: [4096]u8 = undefined;
    const win32_message = try formatOpenGLStartupFailureMessage(&win32_buf, error.Unexpected, .{
        .step = .create_context,
        .win32_error = c.ERROR_MOD_NOT_FOUND,
        .zig_error_name = "Unexpected",
    }, test_arm64);

    try std.testing.expect(std.mem.indexOf(u8, win32_message, "Win32 error: 126 (ERROR_MOD_NOT_FOUND)") != null);
    try std.testing.expect(std.mem.indexOf(u8, win32_message, "OpenCL, OpenGL, and Vulkan Compatibility Pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, win32_message, "Qualcomm ships no desktop OpenGL driver") != null);
    try expectNoVendorGpuAdvice(win32_message);

    // Path 3: neither a detected version nor a Win32 error.
    var bare_buf: [4096]u8 = undefined;
    const bare_message = try formatOpenGLStartupFailureMessage(&bare_buf, error.OpenGLOutdated, .{
        .step = .version_check,
        .zig_error_name = "OpenGLOutdated",
    }, test_arm64);

    try std.testing.expect(std.mem.indexOf(u8, bare_message, "Win32 error: not reported") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare_message, "OpenCL, OpenGL, and Vulkan Compatibility Pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare_message, "https://github.com/amanthanvi/noctty/issues/64") != null);
    try expectNoVendorGpuAdvice(bare_message);
}

// noctty has no DirectX or ANGLE fallback renderer. The ARM64 advice must
// describe the Microsoft mapping layer without implying otherwise.
test "win32-opengl-startup-arm64-message-does-not-claim-a-fallback-renderer" {
    var buf: [4096]u8 = undefined;
    const message = try formatOpenGLStartupFailureMessage(&buf, error.OpenGLOutdated, .{
        .step = .version_check,
        .zig_error_name = "OpenGLOutdated",
        .detected = .{ .major = 1, .minor = 1 },
    }, test_arm64);

    try std.testing.expect(std.mem.indexOf(u8, message, "does not include a software, DirectX, or ANGLE fallback renderer") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "noctty cannot start below OpenGL 4.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "noctty supports DirectX") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "fallback to Direct3D") == null);
}

// Nothing about the x64 advice changes; only ARM64 gets new wording.
test "win32-opengl-startup-x64-message-keeps-the-gpu-vendor-advice" {
    var buf: [4096]u8 = undefined;
    const message = try formatOpenGLStartupFailureMessage(&buf, error.OpenGLOutdated, .{
        .step = .version_check,
        .zig_error_name = "OpenGLOutdated",
        .detected = .{ .major = 1, .minor = 1 },
    }, test_x64);

    try std.testing.expect(std.mem.indexOf(u8, message, "Architecture: x64 process on x64 Windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "updating or reinstalling your GPU driver") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Windows Graphics settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Compatibility Pack") == null);

    var win32_buf: [4096]u8 = undefined;
    const win32_message = try formatOpenGLStartupFailureMessage(&win32_buf, error.Unexpected, .{
        .step = .load_opengl32,
        .win32_error = c.ERROR_MOD_NOT_FOUND,
        .zig_error_name = "Unexpected",
    }, test_x64);

    try std.testing.expect(std.mem.indexOf(u8, win32_message, "OEM AMD graphics driver, then the NVIDIA driver") != null);
    try std.testing.expect(std.mem.indexOf(u8, win32_message, "Compatibility Pack") == null);
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
