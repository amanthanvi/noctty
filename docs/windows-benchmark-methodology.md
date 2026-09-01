# Windows benchmark methodology

This document separates reproducible software regression checks from Windows
desktop presentation measurements. Results are comparable only when the target,
workload, machine fingerprint, display mode, power state, font, dimensions,
build mode, run count, seed, endpoint, and observer disclosures match.

## Headless regression baseline

Recorded 2026-08-29 with Zig 0.15.2, `ReleaseFast`, Windows build 26200, an AMD
Ryzen 9 9900X (12 physical / 24 logical cores), 4,194,304-byte payloads, seed
121, 45 rows, and 140 columns. The dev figures use three runs per workload;
the runner figures and CI gate use five. These
parser/terminal-state results do not exercise ConPTY, the renderer, OpenGL,
DWM, or the display.

The build graph applies the selected optimize mode to every reachable root,
generated, lazy, and transitive Zig module and fails construction on a mode
mismatch. This prevents a nominal `ReleaseFast` executable or benchmark from
silently retaining Debug modules inside the same compiler invocation.

| Workload | Dev median | Runner median | Runner slowest run | CI minimum |
| -------- | ---------: | ------------: | -----------------: | ---------: |
| ASCII    |   195 MB/s |       78 MB/s |          77.7 MB/s |    50 MB/s |
| UTF-8    |   115 MB/s |       61 MB/s |          59.8 MB/s |    35 MB/s |
| OSC      |    13 MB/s |      5.8 MB/s |           5.8 MB/s |     3 MB/s |
| Scroll   |   196 MB/s |       79 MB/s |          63.3 MB/s |    50 MB/s |

The CI minimum is set against the **runner** columns, not the dev column. The
pinned `windows-2025` runner is roughly 2.5x slower than the baseline machine,
so a tolerance derived from dev numbers is meaningless there.

The gate takes a median of five runs, and the first run on a workload can be a
long way under the steady state: in the run these figures come from, scroll run 1
measured 63.3 MB/s against 79.0-80.0 MB/s for runs 2-5. There is no warmup run,
so the floor has to clear that cold outlier and not merely the median. The
earlier 70 MB/s ascii/scroll floors did not: they sat 4% under the ascii median
and above observed individual scroll runs, so only the median-of-5 was keeping
them green. The floors are now set under the slowest observed run, not under the
median.

Figures are rounded because they do not warrant more precision. Each dev figure
was taken three times on an otherwise idle machine and reproduced within about
1% (ASCII 194.65 / 195.17 / 195.93; UTF-8 114.55 / 116.87 / 114.47; OSC 13.48 /
13.40 / 13.61; Scroll 196.99 / 194.63 / 196.76). Runner figures are read from
the CI gate step's own log on this branch, which uses five runs.

Machine load dominates these numbers, so treat any single run on a busy machine
as a lower bound rather than a regression. The same four workloads on the same
commit measured roughly 25% lower while a parallel build was saturating the
disk. That is the reason for the wide CI tolerances, and the reason this table
is not a cross-machine performance claim.

These floors are catastrophic-regression guards, not performance targets. The
class they exist to catch is a build-graph mistake that silently links Debug
dependencies into a nominally `ReleaseFast` benchmark, which under-reports
throughput by 25-46x — far below any of these floors on either machine.

The palette baseline used 5,000 entries and 5,000 deterministic keystrokes on
the same machine: p50 89 us and p99 128 us. CI uses a conservative 1,000 us p99
ceiling. These wide tolerances are catastrophic-regression guards for a pinned
Windows runner image and Zig toolchain; they are not a claim that different CI
hardware has comparable absolute performance.

Reproduce the headless gates:

```powershell
zig build bench:vt-throughput -- --workload=ascii --bytes=4194304 --seed=121 --runs=5 --rows=45 --cols=140 --min-mb-s=50
zig build bench:vt-throughput -- --workload=utf8 --bytes=4194304 --seed=121 --runs=5 --rows=45 --cols=140 --min-mb-s=35
zig build bench:vt-throughput -- --workload=osc --bytes=4194304 --seed=121 --runs=5 --rows=45 --cols=140 --min-mb-s=3
zig build bench:vt-throughput -- --workload=scroll --bytes=4194304 --seed=121 --runs=5 --rows=45 --cols=140 --min-mb-s=50
zig build bench:palette-match -- --entries=5000 --keystrokes=5000 --budget-us=1000
```

## Measured interactive baseline

First same-machine interactive baseline, recorded 2026-08-27 from
`close-noctty-all-final-schema-n5-v3.json`. noctty `1.3.2-dev+windows`,
`ReleaseFast`, commit `d031dc4`, exe SHA-256 `1a1bb883…a50378b`, Consolas 16 pt,
45 rows x 140 columns, N = 5 per metric (`frame_time_p95_ms` pools 201 swap
intervals).

**These rows have not been re-measured since the code was reorganized.** The
run above predates the split of the startup and renderer fixes into their own
change and the move of WGL selection and benchmark tracing into
`src/apprt/win32/`. That work relocated code and removed three benchmark-only
diagnostic controls; it was not intended to change the measured behavior, but
the exact binary these numbers came from no longer exists. Re-run
`test/windows/bench-windows.ps1` on an interactive desktop and replace this
table before citing any figure in it as a current claim. The headless table
above was re-measured on the current tree; this one was not.

Machine: Windows build 26200; AMD Ryzen 9 9900X (12 physical / 24 logical);
NVIDIA GeForce RTX 5070 Ti driver 32.0.16.1088; primary display 3840x2160 at
240 Hz, 150% scale; AC power.

| Metric                        |     Median |        p95 | PRODUCT.md budget |
| ----------------------------- | ---------: | ---------: | ----------------- |
| Stream throughput             | 26.08 MB/s | 28.13 MB/s | none              |
| Alt-screen throughput         | 24.66 MB/s | 24.74 MB/s | none              |
| Scroll throughput             | 27.56 MB/s | 28.91 MB/s | none              |
| Frame time                    |    4.13 ms |    4.49 ms | none              |
| Cold start (app, first swap)  |     297 ms |     313 ms | under 300 ms      |
| Cold start (harness, incl. process creation) | 381.68 ms | 393.65 ms | none |
| Memory per additional pane    |   32.14 MB |   32.72 MB | under 20 MB       |
| Idle CPU                      |       0.0% |       0.0% | effectively 0%    |
| Idle GPU                      |       0.0% |       0.0% | effectively 0%    |
| Idle successful swaps / 10 s  |          0 |          0 | no timer churn    |
| ConPTY round trip             |      78 ms |     141 ms | none              |
| Key to first swap (proxy)     |   56.56 ms |   68.10 ms | not comparable    |

Read this table with the endpoint definitions below. Two results miss a
`PRODUCT.md` budget and are published as measured rather than adjusted:

- **Memory per additional pane is 32.14 MB against a 20 MB budget.** The figure
  is whole-process private bytes, so it combines terminal, renderer, native
  heap, and OpenGL driver commit for the new surface; it is not apportioned.
- **Cold start medians 297 ms against an under-300 ms budget, with a 313 ms
  p95.** The median is inside the budget and the tail is not, which is why the
  cold-start threshold stays inactive pending a percentile decision.

`key_to_first_swap_ms_proxy` is a software proxy, not the product's key-to-pixel
budget; see "Physical key-to-pixel procedure". Cold-start and swap timestamps
derive from `GetTickCount64`, whose resolution is about 15.6 ms.

## Interactive Windows metrics

Run `test/windows/bench-windows.ps1` directly on an interactive Windows 11
desktop with `ReleaseFast`, Consolas 16 pt, 45 rows, 140 columns, seed 121, and
at least five runs. The evidence schema records the executable hash, commit,
machine/display fingerprint, endpoint, observers, and threshold provenance.

- Interactive throughput starts after a ready/go barrier. No workload assumes
  ConPTY preserves the producer's original byte count. The child emits a
  unique visible marker after every payload, and the benchmark-only terminal
  observer confirms that token in the reconstructed visible grid before
  latching its committed output generation/count. The endpoint is the first
  successful swap at or after that generation. For alternate-screen runs,
  `1049l` is sent only after evidence release. Producer blocking, downstream
  backpressure, and the observer's bounded top-row scan are included.
- `frame_time_p95_ms` pools QPC intervals between consecutive successful swaps
  after the stream target is armed and through its first full-consumption swap.
  It is a software renderer-present cadence metric. It excludes DWM composition,
  scanout, pixel response, and photons.
- Detailed termio profiles are diagnostic-only and process-lifetime scoped.
  `ReadFile` totals include blocking before the go marker. Profiled runs cannot
  be used as product gates.
- The Windows PTY reader uses a 64 KiB batch. There is no runtime override;
  every metric and gate measures that one product path.
- Memory uses the main process `PrivateMemorySize64`; child shells are excluded.
  Each run records the marginal private-byte change after every new pane, then
  targets those exact surfaces with `close_surface`, verifies the pane count
  returns to one, retains the exact new surface IDs in evidence, and records
  reclaimed and residual private bytes after a seven-second post-destroy settle.
  `close_surface` clears structural history and destroys these native surfaces
  synchronously; the settle observation is allocator/driver behavior, not undo
  retention. Each Win32 Surface owns one persistent WGL context.
  Pixel-format selection also creates and deletes one short-lived display-local
  bootstrap WGL context before the Surface context is created. Process private
  bytes combine terminal, renderer, native-heap, and OpenGL-driver commit and
  may retain driver allocation/cache effects from both contexts after bootstrap
  deletion; the evidence therefore discloses that combined scope rather than
  pretending to apportion bytes to the driver.
  The memory trace also requires exact teardown stages for core deinit, WGL
  unbind/context deletion, DC release, and final Surface resource cleanup. A
  missing stage fails the metric instead of assuming a native cleanup API
  succeeded. Each teardown stage is emitted only when the call it names
  reported success: `wgl_context_deleted` requires a `wglDeleteContext` that
  returned non-zero, `dc_released` a `ReleaseDC` that returned non-zero
  against a window we still held, and `wgl_context_unbound` either a
  successful `wglMakeCurrent(null, null)` or a context that was already not
  current on the destroying thread. A failed cleanup therefore omits its
  stage and fails the run, rather than letting stage presence alone assert a
  release that never happened.
  `surface_destroy_complete` is sampled after `App.windowDestroyed` detaches
  the surface, because that call is still per-pane teardown: it removes the
  surface from `App.windows`, discards the structural-history entries
  referencing it, deinitializes the owning tab and its split tree when this
  was the tab's last pane, and reconciles pending shell state. Sampling
  before it would draw the private-memory boundary in the wrong place and
  misattribute those still-held bytes to allocator or driver behaviour. Two
  per-surface allocations are still live at that point and are freed
  immediately afterward: the `Surface` itself, since the snapshot cannot
  outlive the object recording it, and the absolutized trace path owned by
  `MemoryStageTrace`. Both predate `surface_begin`, so stage deltas cancel
  them. The external headline pane-memory metric still includes the trace
  path allocation, which its observer-scope disclosure calls out.
  The stage list is exactly the set of boundaries the runtime actually
  emits: `surface_begin`, `child_hwnd_created`, `gl_context_created`,
  `opengl_functions_loaded`, `renderer_initialized`, `terminal_initialized`,
  `renderer_thread_spawned`, `io_thread_spawned`, `threads_started`,
  `io_reader_spawned`, `first_successful_swap`, and the six teardown stages.
  DC acquisition and the first `wglMakeCurrent` are reported as the single
  `gl_context_created` boundary because both happen inside one `App` method
  with no surface in scope; splitting them would name two stages the trace
  cannot separate. Render-target strategy provenance is deliberately **not**
  in the trace: recording it needs a renderer-to-apprt seam that does not
  exist, and the direct-default-framebuffer precondition is enforced at its
  source by the runtime `GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING` query in
  `OpenGL.init` plus the `targetStrategy` unit tests, not by benchmark
  evidence.
  Selected-format evidence records actual color, alpha, depth, stencil,
  stereo, accumulation, and auxiliary-buffer properties. Extended selection
  uses one of three pairings, tried in order and never mixed:
  `WGL_EXT_pixel_format` with either framebuffer-sRGB spelling
  (`WGL_ARB_framebuffer_sRGB` or `WGL_EXT_framebuffer_sRGB`, both of which
  declare 0x20A9 against the EXT entry points); `WGL_ARB_pixel_format` with
  `WGL_EXT_colorspace` set to `WGL_COLORSPACE_SRGB_EXT`; or, last,
  `WGL_ARB_pixel_format` with either framebuffer-sRGB spelling queried
  through `wglGetPixelFormatAttribivARB`. The first two are the spec-exact
  pairings; the third is the de-facto pairing mainstream loaders use, and it
  is tried last so that a driver matching a spec-exact pairing keeps that
  path. Without it, a driver advertising `WGL_ARB_pixel_format` and
  `WGL_ARB_framebuffer_sRGB` but not `WGL_EXT_pixel_format` would match no
  pairing and silently fall back to classic selection. The selected family is
  recorded explicitly; classic fallback first deterministically enumerates and
  ranks the described formats. If a driver exposes no strict-compatible
  descriptor through that inventory, the still-untouched real DC uses the
  prior depth-constrained `ChoosePixelFormat` request and validates its actual
  described format before the one permitted `SetPixelFormat` call.
  Both extended paths require stereo off and full hardware acceleration. Formats
  without accumulation, auxiliary, depth, or stencil attachments rank first,
  but a base-compatible format with those attachments remains usable and its
  actual counts are recorded rather than hidden. Modern direct candidates still
  require both sample buffers and samples to be zero whenever the selected API
  family can query them: the EXT pixel-format path recognizes either
  `WGL_EXT_multisample` or `WGL_ARB_multisample`, while the ARB pixel-format path
  requires `WGL_ARB_multisample`. Absence of the family-compatible query
  capability is recorded explicitly with null sample counts rather than
  presented as a measured zero.
  Extended selection first requests a bounded inventory of base drawable RGBA
  matches; acceleration, sRGB, stereo, and multisample rules are applied only
  after every returned match is queried. Attachment counts remain ranking and
  provenance inputs. If that post-filter produces no verified
  format, selection falls back to the classic request and the selected-format
  evidence records what was actually chosen.
  `-MemoryCycles`
  repeats one-to-four-to-one pane lifecycles in the same process, from one to
  five cycles. Every nondefault option is Noctty-memory-only and is rejected
  with `-Gate`. Each cycle records its baseline and live private bytes, exact
  globally unique created surface IDs, every create/close pane count, the
  seven-second post-destroy settle, reclaimed bytes, and residual bytes. Repeated-cycle
  samples intentionally include prior-cycle allocator and driver-cache state.
  The low-level `surface_token` is an allocator address scoped to one serialized
  `surface_begin` incarnation, so it may repeat after an earlier Surface is
  destroyed. The parser partitions such records at `surface_begin`, keeps the
  exact globally unique `surface_id` as evidence identity, and rejects token
  sharing within the current cycle or mixed IDs inside one incarnation.
  Evidence records the cycle count and `memory_diagnostic_only`; repeated-cycle
  collections cannot be combined with `-Gate`, so they cannot certify the
  product memory budget.
- Idle children explicitly request the steady DECSCUSR cursor (`CSI 2 SP q`).
  The harness establishes foreground ownership before the baseline and records
  exact terminal-surface focus transitions. Any transition during the timed
  interval invalidates the sample as environmental contamination rather than
  weakening the zero-present product assertion.
  The timed interval begins only after the same locked renderer snapshot used
  to build the frame reports `cursor_blinking=false` and every render, paint,
  swap, and presented-output counter remains unchanged for 1,500 ms (more than
  two 600 ms cursor intervals). The closing snapshot must remain non-blinking.
  This excludes startup-tail work without hiding recurring idle activity: if
  the app cannot become quiescent before the deadline the metric errors, and
  any counter change after the timed baseline remains a failure. Evidence
  retains the settle duration/probe count and the before/after delta for every
  render-trace counter. Wake-source deltas separately identify core surface,
  cursor timer, repaint retry, resize settle, paint retry, renderer health
  recovery, and already-pending-paint notifications; they are diagnostic
  attribution, not a substitute for the authoritative update/paint/swap
  counters. During the short lost-wake protection window, the
  renderer's follow-up timer continues polling terminal dirtiness, but a clean
  poll does not rebuild or present another frame.

Every target PID returned by `Start-Process` is recorded with its run name,
resolved executable path, start time, cleanup method, confirmed exit, and exit
time. Evidence emission fails schema validation if cleanup did not confirm the
exact returned process exited.

`bench-thresholds.json` records every current value as provisional and inactive.
That includes the literal `PRODUCT.md` cold-start, memory, and no-idle-swap
budgets: `PRODUCT.md` explicitly leaves them provisional until a same-machine
baseline and tolerance are reviewed. Inactive thresholds are emitted with
`passed: null`; they cannot silently fail or pass a gate. Threshold files must
use actual JSON booleans, and the harness rejects any threshold that is both
active and provisional.

Threshold provenance is attached to every measured metric whether or not
`-Gate` was passed, so a baseline record still carries the direction, value,
`active`, `provisional`, `source` and `passed` that the comparison produced;
the schema requires a `threshold` object on any metric that reports a median
with `pass` or `fail` status. `-Gate` decides only whether a breach turns into
a failing metric status and a nonzero exit, and it fails closed when the
selected metrics have no applicable active threshold or contain an error,
skipped, or adapter-required result. Until a reviewed threshold is activated,
run interactive metrics as baseline collection without `-Gate`; a schema-valid
`pass` record then means collection succeeded, not that a product budget was
certified. The separate
headless CI regression gates below use their documented workload-specific
baseline and tolerance rather than this interactive threshold file.

The current interactive threshold evaluator compares `frame_time_p95_ms` at
p95 and every other metric at its median. The median statistic used for cold
start is not yet approved for the literal `PRODUCT.md` wording, "under 300 ms":
a median below 300 ms can still leave a material tail above the budget. The
corrected N=5 baseline measured a 297 ms median and a 313 ms p95. Cold start
therefore remains inactive; activation must explicitly review the percentile
(preferably p95 or stricter), its sample count, and a same-machine tolerance
before the harness can claim the product budget.

## Competitor comparability

The harness detects Alacritty, Windows Terminal, Tabby, and Wave, but it does
not report producer-only timing as terminal throughput. A competitor metric is
`not-supported` until its adapter proves the same causal endpoint with stable
process/window ownership, either through terminal render instrumentation or a
validated PresentMon ETW capture. Cold-start needs first-present evidence;
memory needs equivalent pane automation and process-tree ownership; idle needs
stable CPU/GPU ownership plus successful-present counts.

On the baseline machine, Alacritty and the packaged Windows Terminal were
installed. The harness resolves Windows Terminal through the newest installed
`Microsoft.WindowsTerminal` AppX package because its app-execution alias can be
a zero-byte reparse point that is not a readable executable. Tabby, Wave, and
PresentMon were not installed. No competitor performance result is
published from that inventory alone.

## Physical key-to-pixel procedure

The software `key_to_first_swap_ms_proxy` is diagnostic. `SendInput` to a
causally acknowledged successful swap excludes compositor delay, scanout,
display response, and photon emission, so it cannot certify the product's
key-to-pixel budget.

For physical acceptance:

1. Fix the display refresh rate, disable variable refresh, use AC power, record
   the machine/display fingerprint, and render a black-to-white controlled cell.
2. Use a hardware key actuator or switch-contact trigger and a photodiode taped
   over that cell, sampled by the same acquisition device. A 1,000 fps or faster
   camera may be used when its exposure and timestamp uncertainty are reported.
3. Capture at least 30 trials for noctty and for the OS/compositor reference on
   the same machine without changing display mode. Publish raw traces or frames,
   trigger/threshold rules, misses, median, p95, and measurement uncertainty.
4. Subtract an OS/compositor floor only when it comes from the matched reference
   procedure. Do not subtract the software swap proxy or compare runs from
   different machines.

Camera/photodiode results and same-machine competitor publication therefore
remain external acceptance items; this repository supplies the software proxy,
evidence contract, and adapter-required disclosures without fabricating them.
