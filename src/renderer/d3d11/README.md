# D3D11 backend

This opt-in Win32 backend uses the shared `GenericRenderer` preparation,
shaping, atlases, dirty ranges, uniforms, and cursor state. OpenGL remains the
default. Each pane owns a D3D11 device and flip-sequential composition swapchain.
A DirectComposition visual targets the terminal HWND below its children. The
SDK C++ companion owns that graph, with System32-only lazy runtime loading.
The terminal renders into an offscreen target before copying to DXGI.

The SDK C bridge owns COM declarations and references. Its fixed shaders are
embedded DXBC in `terminal_bytecode.h`; opted-in surfaces load `d3d11.dll` from System32
and have no shader compiler dependency. To regenerate after editing HLSL, run
`pwsh -NoProfile -File src/renderer/d3d11/generate-shaders.ps1`. The generator
uses SDK 10.0.26100.0 `fxc.exe` by default and accepts `-Fxc <path>`. The header
records the source SHA-256. HLSL consumes the existing 144-byte uniform and
32-byte cell layouts, checked at compile time in `shaders.zig`.

Initialization tries hardware then WARP; `renderer = d3d11-warp` selects WARP
directly. HRESULT failures from resource allocation, resize, Present, and
staging Map are classified with `GetDeviceRemovedReason`. Frame boundaries
also check this reason because D3D11 context drawing/upload calls return void.
Device loss retains CPU buffer contents and complete atlas images. Recovery
recreates shaders, buffers, atlases, targets, and the composition graph. Hardware
retries are limited to one per sixty-second window; repeated loss uses WARP,
and a later loss after cooldown can re-probe hardware. Explicit WARP stays WARP. A failed
recovery candidate is fully released before trying WARP. Failure there marks
the backend unavailable for the runtime's OpenGL fallback.

Recovery invalidates target pixels and the last-rendered pointer. The generic
renderer observes `needsRedraw()` and encodes a full frame, using retained CPU
state, before it can skip unchanged content again. Destroying a target clears
its retained pointer. Zero-sized targets carry metadata without allocating
GPU textures, and zero client sizes never reach DXGI ResizeBuffers.

`DXGI_STATUS_OCCLUDED` retains the completed offscreen frame for readback and
does not count as a successful present or signal the runtime's first-frame
notification. While occluded, actual Present submissions are replaced with a
Present(TEST) probe no more than once per 250 ms. Shared renderer scheduling
and visibility policy remain in control; an idle occluded surface uses the existing
renderer draw timer for 250 ms presentation retries.
Stats distinguish encoded frames, S_OK presents, occlusion responses, tests,
recovery generations, HRESULT/removal reason, and adapter identity. Test builds
also report draw calls, uploaded bytes, CPU encode and Present-call timing,
swapchain dimensions, ResizeBuffers calls, and composition commits. Those values are not GPU time
or visible scanout evidence. Encode timing runs from `beginFrame` to the
completed draw encoding, before resize/copy/presentation work. Present timing
covers normal Present submissions and excludes Present(TEST) probes.

Test hooks require `-Drenderer-test-tools=true` (C macro
`NOCTTY_RENDERER_TEST_TOOLS=1`). Production builds return `E_NOTIMPL` from the
C hooks and reject them at the Zig boundary. Callers must hold the renderer
draw mutex:

- `capture(hdc)` reads the last completed offscreen target into a staging
  texture and draws a DIB;
  its optional `NOCTTY_RENDERER_CAPTURE_PATH` writes the same pixels when a
  cross-process HDC cannot be used. This bypasses DWM composition.
- `requestDeviceLoss()` injects `DXGI_ERROR_DEVICE_REMOVED` into the production
  HRESULT classifier. It exercises recovery and resource restoration; it
  does not reset the system graphics driver or establish real TDR behavior.
- `setTestFailures(hardware, device)` controls creation failures for recovery
  tests. Test-only `NOCTTY_RENDERER_FAIL_HARDWARE=1` and
  `NOCTTY_RENDERER_FAIL_DEVICE=1` configure the same failures at startup.
- `failNextPresent()` supplies an ordinary HRESULT failure to the production
  presentation classifier; `NOCTTY_RENDERER_FAIL_RESOURCE=1` fails hardware
  buffer allocation during initialization. Both verify escalation to WARP.

The hidden-desktop harness stages the checksum-pinned bundled ConPTY pair;
in-box ConPTY can strip Kitty APC and would invalidate image-fallback coverage.
It tests pixel parity, recovery, resize, synthetic DPI scale round trips,
minimize/restore, paced idle occlusion probes, tabs/splits, config reload, and
fallback. Physical multi-monitor transitions and unoccluded scanout remain
outside this harness's evidence.

Supported drawing includes global/cell backgrounds, grayscale/BGRA atlases,
minimum contrast, native/linear/corrected-linear blending, cursor glyphs,
resize, and DPI-derived physical target sizes. Configured custom shaders and
background images are prechecked by the runtime; live Kitty image use causes
runtime fallback. The backend's corresponding texture/pipeline APIs also
reject unsupported use. Feature level 11.0 is required. There is no
per-pixel translucency, GPU timer query, or claim of visible-presentation
performance from hidden-desktop measurements.

Default OpenGL forwards through a stable atomic pointer with no dispatcher mutex;
its generic renderer owns exactly its original locks. GL functions are loaded at
the original pre-font stage. Presentation timer reconciliation occurs only when
the D3D pending state changes.

Before fallback, detach the composition root, commit the detachment, release
the graph/backbuffer/swapchain, and
flush deferred destruction. Keep the D3D device and terminal resources until GL
construction succeeds. On failure, D3D recreates presentation and continues text;
shader/image capabilities prevent unsupported GPU work. Detachment is asynchronous;
old pixels may briefly remain while DWM applies the commit. No compositor completion
wait runs on the UI thread, and a successful Commit is not scanout evidence.

The CPU mirrors are intentionally retained in this beta to reconstruct resources
before generic GPU preparation. A 2048-square gray/color atlas pair adds roughly
20 MiB per pane; replacing mirrors with forced shared-atlas resync is deferred.
The backend adds compatibility for software/GL-unavailable sessions; no visible
latency or throughput advantage over OpenGL is claimed.
