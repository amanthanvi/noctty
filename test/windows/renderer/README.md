# Isolated renderer verification

Build with `zig build -Doptimize=ReleaseFast -Dcustom-shaders=true
-Drenderer-test-tools=true`, then run `Invoke-RendererParity.ps1 -Binary
<prefix>/bin/noctty.exe -OutputDirectory <new directory>`. On a development
host, add `-RequireHardware` to require hardware parity rather than accepting
WARP as the hardware candidate. `-WarpOnly` runs lifecycle coverage without
needing an OpenGL 4.3 driver and is used on hosted x64 and native ARM64 CI.

Every run copies the executable beside `noctty.portable`, stages the pinned
ConPTY pair, redirects both app-data roots, verifies a private desktop, and
checks the real startup-profile hash and mtime before and after launches.
The caller can pin the accepted baseline with `-ExpectedProfileHash` and
`-ExpectedProfileMtime`. Use an immutable source prefix; the harness checks
each copied executable against the initial hash. It never takes foreground.

Each synchronous capture must create fresh in-app BMP pixels and JSON status.
The diagnostic GDI PNG is not accepted as framebuffer evidence. OpenGL test
builds use an offscreen target. Hardware must match OpenGL exactly; WARP is
allowed at most four channel levels of difference, one percent differing
pixels, and 0.1 percent of pixels over two levels. Recovery and physical-size
restoration must reproduce each backend's original frame exactly.

Coverage includes device reconstruction, allocation/Present/creation/library
failure escalation, resize, synthetic DPI scaling, minimized visibility,
idle occlusion probes, tabs/splits and pane closure, streaming output under
power-saver pacing, shader reload, and unsupported-feature fallback. The DPI
test calls the production surface scale callback and restores physical
geometry; it does not simulate a real monitor crossing or host WM_DPICHANGED.
The fault hooks exercise production HRESULT handling, without resetting the
system graphics driver. Every local case must close gracefully; the exact-PID
fallback exists only for cleanup after a failure.

Local 2026-10-10 measurements on the NVIDIA RTX 5070 Ti:

- Hardware: zero differences out of 1,533,852 pixels.
- WARP: 8,592 differing pixels, maximum delta four, 89 pixels over two levels.
- Hardware/WARP reconstruction, resize return and DPI scale return: exact.
- The original HWND-swapchain hidden run was occluded. Composition Present
  receipts in later runs can succeed, but still establish no scanout, GPU-completion latency,
  physical TDR, monitor hotplug, or RDP claim follows from these captures.

One-binary coexistence was retained after comparing ReleaseFast production
builds with custom shaders enabled: OpenGL-only was 31,064,064 bytes and the
combined binary 31,176,704 bytes, an increase of 112,640 bytes (0.36%).
Dependency-cached build wall times were 176.69 and 172.15 seconds respectively
at BelowNormal priority. These single runs share a busy host and do not prove
a compilation speedup; no material wall-time penalty was observed.

## Review follow-up checks

`-WarpOnly` also forces GL initialization failure while Kitty content arrives and
while a reload enables a shader/background image. Text frames must keep advancing.
Resize now checks actual swapchain dimensions and a new ResizeBuffers receipt,
in addition to offscreen readback. Host notices are suppressed only in this
test-tools parity run to keep reference geometry identical; production and the
visible check retain them.

Build two production binaries with custom shaders, one default and one with
`-Dd3d11=false`. Run `Invoke-OpenGLScheduling.ps1 -DefaultBinary <exe>
-OpenGLOnlyBinary <exe> -OutputDirectory <new directory>` for an isolated hidden
streaming/live-resize comparison. It records output progress, frame updates, and
UI resize/snapshot response times. Run `../interactive-win11-shader-pacing.ps1
-Binary <exe> -OutputDirectory <directory>` on the same verified hidden driver
for each binary. The supplied binary is copied beside a portable marker before
launch; these measurements describe CPU/UI behavior, not visible scanout latency.

The maintainer runs `Invoke-VisibleD3D11Check.ps1 -Binary <production exe>` on
their own desktop for palette, paste preview/Allow/Cancel, scrollbar, quick-select,
opacity, and Kitty-to-GL presentation. It records individual pass/fail/skip ratings
and offers an optional cropped screen capture per step. `-PrepareOnly` performs
staging without launching; agents must use that switch. A skipped visible step
stays incomplete, and readback is never substituted for displayed content.
