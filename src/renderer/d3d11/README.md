# D3D11 backend

This opt-in Win32 backend uses the shared `GenericRenderer` preparation,
shaping, atlases, dirty ranges, uniforms, and cursor state. OpenGL remains the
default. Each pane owns a D3D11 device and flip-sequential HWND swapchain.
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
recreates shaders, buffers, atlases, and target objects. One hardware retry is
allowed across the backend lifetime; subsequent loss uses WARP. A failed
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
also collect CPU encode and Present-call timing; those values are not GPU time
or visible scanout evidence. Encode timing runs from `beginFrame` to the
completed draw encoding, before resize/copy/presentation work. Present timing
covers normal Present submissions and excludes Present(TEST) probes.

Test hooks require `-Drenderer-test-tools=true` (C macro
`NOCTTY_RENDERER_TEST_TOOLS=1`). Production builds return `E_NOTIMPL` from the
C hooks and reject them at the Zig boundary. Callers must hold the renderer
draw mutex:

- `captureBmp(path)` reads the last completed offscreen target into a staging
  texture and writes a top-down 32-bit BMP. `capture(hdc)` also draws a DIB;
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
DirectComposition path, GPU timer query, or claim of visible-presentation
performance from hidden-desktop measurements.
