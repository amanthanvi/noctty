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
It scales down to three quarters of the host's DPI everywhere, and up to 192
DPI only where the scaled host fits the monitor's work area: a host that cannot
grow shrinks the grid, and since PKG-14 a Windows pty does not pull the rows it
pushed into history back when the grid grows again, so that round trip cannot
be exact (a 1024x768 hosted runner records why it skipped the upscale).
The split-dim cases (`unfocused-split-opacity`, #408; `-SplitDimOnly` runs
just them) split the window so both panes show the fixture and check that
each dimmed capture equals its undimmed capture blended toward the fill at
`1 - opacity` in sRGB space, every pixel within two levels (the fixture hides
the cursor for them, because its shape follows keyboard focus). They move
focus with `goto_split`, zoom and unzoom, recreate the D3D11 device, reload with a
custom shader (the dim lands after it; D3D11 moves to OpenGL and keeps it)
and with opacity 1, close a pane, and compare the dimmed frame across
backends with the parity tolerances above. `-WarpOnly` runs the WARP case
without the shader reload. The held case keeps synchronized output open in
the fixture and captures without a redraw, so only what the renderer presents
itself is read; it runs on OpenGL, because a D3D11 pane on a hidden desktop is
always occluded and its paced present retry carries any change through a hold.
The IME composition caret cases (#527; `-PreeditCaretOnly` runs just them, and
`-WarpOnly` runs the WARP one) show a composition through the test-tools
message `0x8059`, which skips only the IMM read: `wParam` picks a fixture (1
`zhongguo`, 2 three CJK characters, 3 208 letters, wider than the grid, 0
clears) and `lParam` is the `GCS_CURSORPOS` value (-1 for none). The cursor
colour is set to one no fixture text uses, so the terminal's block cursor in
the first capture gives the cell, and the caret is the only thing in that
colour afterwards. Each case checks a bar on the left edge of the sixth
preedit cell at cursor 5, moved one cell left at 4, at the first cell at 0,
one cell past the text at 8, between wide characters, at the first column for
a caret in the cut head of an overlong composition and on the last column for
one at its end, no bar for -1, and the block cursor back when the last step
clears the composition. The same cases check the conversion target clause
(`GCS_COMPATTR`) with fixtures 4-7, six wide characters in three
two-character clauses: no attributes (4), the target on the second clause (5)
or the third (6), and attributes one short of the string (7). Every pixel that
differs between 4 and 5 must lie under preedit cells 4-7, across their full
width and below the middle of the row, and between 4 and 6 under cells 8-11;
5 and 6 differ only in those underline rows, 7 draws exactly what 4 does, and
a caret before the target keeps both the bar and the double underline. The
shape is counted too: in each of 4, 5 and 6, the rows on which every pixel of
a clause's four cells is lit (no glyph stroke crosses the gap between its two
characters) form one band per clause, the same band in every clause, and two
bands below the middle of the row under the target clause. Before the last
step, captures that ask for no redraw check that the bar stays put through
frames the composition did not cause. After the fixture turns cursor blinking
on and writes nothing, at least two blink frames
in 2.5 s must rebuild with the preedit row clean (the renderer counts them in
its status as `preedit_caret_clean_rebuilds`), the frames a caret drawn only
with the preedit's cells would vanish from. Then the fixture writes to another
row for a second and a half; that output also dirties the cursor's row,
because the cursor moves there and back. The cases run on OpenGL, D3D11
hardware and WARP (hardware matching OpenGL exactly, WARP within the
tolerances above) and once with the fixture's cursor hidden (DECTCEM off).
No IME is installed, switched or driven.
The palette theme cases (`-PaletteThemeOnly` runs just them, and `-WarpOnly`
runs the WARP one) read the command palette's theme preview, cancel and commit
from the renderer's own frames, so nothing on the screen can disturb them.
`../interactive-win11-palette-theme.ps1` reads screen pixels, and a
release-evidence run of it once read `3c3c3c`, which is no noctty colour, where
it expected Dracula (attributed to another window over the app, not measured).
The fixture's config sets `theme = Dracula`, whose background is `282a36`, and
no background or foreground of its own. The case opens the palette through the
host's toolbar hook (`WM_COMMAND` 1901) and sets its query edit to `0x96f`, a
theme with background `262427`. It then polls fresh readbacks until the most
frequent colour of the frame (`dominant` in the receipt) is that background,
while the config file still says Dracula. A click on the palette's cancel
button must bring `282a36` back with the file unchanged. Opening the palette
again and clicking its first result commits the theme: the palette closes and
the file says `0x96f`. The commit saves the file and reloads from it, so the
frame is `262427` in the first readback after the palette closes and again one
second later; both sampled readbacks must show it. They are samples: a frame
that went back to Dracula only between them is not seen, which would take a
renderer-side frame history. A
wait for a colour gives up after 20 seconds and names the colours it saw in
order, and a wait for a palette control or for the saved file gives up after
10. The case fails at once under High Contrast, where the palette does not
preview a theme, and checks that each label ran on the backend it names. It
runs on OpenGL (which needs an OpenGL 4.3 driver, so not under `-WarpOnly`),
D3D11 hardware and WARP. The readback is the render target, so it does not
prove what DWM composes, and the High Contrast suppression is for
`interactive-win11-palette-theme.ps1 -ExerciseHighContrast` to check.
Readback is the render target before DWM: the production OpenGL path that
draws straight into the window's sRGB framebuffer (off in test-tools builds)
and D3D11 after composition need a visible check.

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
visible check retain them. The OpenGL startup fallback case reads its banner
through UIA instead, and sets `NOCTTY_RENDERER_KEEP_NOTICES` (also honoured only
by test-tools builds) so the banner stays up: an info banner counts down from its
first paint, so a UI thread that is busy past the countdown no longer clears it
unseen, but a slow UIA client may not reach it until the countdown is over.
Before the launch the case makes one UIA read of its own desktop's root,
which needs nothing from the app (`warmupMs`), so the UIA client's first-call cost
comes before the banner wait. It reads the banner only once it is shown, and
times a `WM_NULL` round trip to the host just before each read (`longestPingMs`);
a slow one means the app's UI thread was not pumping messages, or the machine was
too busy to run either process. The `bannerWait` receipt also records the first poll that saw the banner shown
(`shownMs`), the reads, the longest one, when the read that found the name
started and ended (`foundReadStartMs`, `foundMs`), and the last name read. The
app reads the name at some point during that read, so
`foundReadStartMs - shownMs` is a lower bound on how long the banner had to stay
up. `foundMs - shownMs` is not a bound, because the read's own time can be spent
in the UIA client.

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
