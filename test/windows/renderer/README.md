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
- The composition swapchain run was also occluded. These captures establish no
  scanout, GPU-completion latency, physical TDR, monitor hotplug, or RDP behavior.

One-binary coexistence was retained after comparing ReleaseFast production
builds after the main rebase, with custom shaders enabled: OpenGL-only was
31,155,712 bytes and the combined binary 31,276,544 bytes, an increase of
120,832 bytes (118 KiB, 0.39%). Dependency-cached build wall times were 166.99
and 212.36 seconds respectively at BelowNormal priority. These single runs
share a busy host and do not isolate the backend's compilation cost.

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

After the review fixes and main rebase, three shader-pacing runs per production
binary each presented all six input/output steps (100 ms polling): default
106-125 ms, OpenGL-only 118-128 ms. Animation remained at 20.7 swaps/s for default
and 20.7-21.7 for OpenGL-only. Each run presented 370 new PTY bytes. This checks
progress under saver pacing; it does not measure keyboard-to-scanout latency.

Streaming during 80 alternating live resizes per binary also kept advancing:

| Production build | UI resize/snapshot p50 / p95 / max (ms) | Frame updates | Presented PTY bytes |
| --- | --- | --- | --- |
| Default | 13.11 / 18.65 / 20.42 | 142 | 170,023 |
| `-Dd3d11=false` | 12.39 / 22.54 / 25.98 | 145 | 169,960 |

These are one sequential comparison on a shared host, including snapshot work;
they show continued progress and bounded UI response, without a speedup claim.

The maintainer runs `Invoke-VisibleD3D11Check.ps1 -Binary <production exe>` on
their own desktop for palette, paste preview/Allow/Cancel, scrollbar, quick-select,
opacity, and Kitty-to-GL presentation. It records individual pass/fail/skip ratings
and offers an optional cropped screen capture per step. `-PrepareOnly` performs
staging without launching; agents must use that switch. A skipped visible step
stays incomplete, and readback is never substituted for displayed content.
