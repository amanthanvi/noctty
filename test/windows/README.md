# Windows Tests

Manual and interactive harnesses for Windows-specific functionality.

Each interactive Win11 harness uses its own repo-local sandbox under
`.sandbox\win11\<worktree-id>\<sandbox-name>`, so `-ResetState` resets
only that harness's logs/temp state instead of tearing down sibling
validators.

## ci-scripts.ps1

Tests for the CI helper scripts: the pull-request path filter
(`scripts/ci-changed-paths.ps1`), the gate job's logic (`scripts/ci-gate.ps1`)
and the parsers of the report-only nightly jobs (`scripts/ci-test-timing.ps1`,
`scripts/ci-bench-trend.ps1`). `.github/workflows/test.yml` runs one
always-on `checks` job (contracts, shell integration, site and release copy)
and independent compiled jobs (`tests`, `bench`, `build`, `renderer-smoke`,
`cross-arm64`, libghostty-vt, ConPTY probes, portable smoke), and
`windows-arm64.yml` splits its tests from its package build. On a pull request
a `changes` job lists the changed files, and a change that touches only files
no compiled job reads (docs, the site, release and check scripts, harnesses
the `checks` job runs) skips the compiled jobs with a job-level `if:`. A skipped
job reports success, so no required check is left pending, and the gate jobs
(`Windows Build And Tests`, `Native Windows ARM64 Tests`) fail when a needed job
did not succeed or a job ran against its flag. The table of skippable files is
an allowlist: a file it does not name runs everything. Push, schedule and manual
runs always run everything.

The test checks fixed cases and the table against the repository: every rule
must match a tracked file; every repository path a Zig source names in a string
literal must run all compiled jobs (a Zig unit test reads
`scripts/package-windows.ps1`, so that script is not "script-only"); and every
file reachable from the scripts a compiled job runs, through dot-sourcing and
`Join-Path`, must keep that job. The reachability scan reads quoted file names
and repo paths, so a script that builds a path at run time is not followed; add
such a file to the table by hand.

```powershell
pwsh -NoProfile -File .\ci-scripts.ps1
```

## interactive-win11-accessibility.ps1

Full interactive UI Automation story for terminal text, focus, notifications,
Settings, themes, High Contrast, and accessibility idle/stress behavior.

```powershell
pwsh -NoProfile -File .\interactive-win11-accessibility.ps1 -ResetState
```

## interactive-win11-key-input.ps1

Validates Win32 keyboard and Unicode input delivery plus focus ownership across
the supported key scenarios.

```powershell
pwsh -NoProfile -File .\interactive-win11-key-input.ps1 -ResetState -Key a
```

## interactive-win11-new-tab.ps1

Validates new-tab creation, focus, and preservation of maximized host-window
state while inactive tabs initialize.

```powershell
pwsh -NoProfile -File .\interactive-win11-new-tab.ps1 -ResetState
```

## interactive-win11-first-frame.ps1

Asserts the window presents terminal content before it is given any input
(#224). Sends no keys and never touches the mouse or the foreground; the
oracle is the render trace the app writes on its first `SwapBuffers`.

```powershell
pwsh -NoProfile -File .\interactive-win11-first-frame.ps1 -ResetState
```

## interactive-win11-configured-size.ps1

Launches a terminal with configured row and column dimensions and verifies the
resulting console and native-window size evidence.

```powershell
pwsh -NoProfile -File .\interactive-win11-configured-size.ps1 -ResetState
```

## interactive-win11-shell-command.ps1

Validates configured `cmd.exe` and PowerShell shell-command launch paths,
captured output, exit status, and failure diagnostics.

```powershell
pwsh -NoProfile -File .\interactive-win11-shell-command.ps1 -ResetState
```

## interactive-win11-shell-command-live.ps1

Types a Noctty CLI action into a live terminal and validates focus, screen
capture, and command output.

```powershell
pwsh -NoProfile -File .\interactive-win11-shell-command-live.ps1 -ResetState -CliAction +help
```

## interactive-win11-pr-smoke.ps1

Serial PR smoke entry point for startup, input, tabs, resize, undo,
accessibility, palette-theme, and session-restore harnesses.

```powershell
pwsh -NoProfile -File .\interactive-win11-pr-smoke.ps1 -ResetState
```

## interactive-win11-stateful-lib.ps1

Dot-sourced helpers for stateful window discovery, Win32 messaging, pixel
sampling, process launch, and cleanup. It is not a standalone harness.

## cli-shell-command.ps1

Runs a Noctty CLI action through `cmd.exe` or PowerShell and verifies its
exit code plus expected redirected text.

```powershell
pwsh -NoProfile -File .\cli-shell-command.ps1 -Shell cmd -Arguments +help -ExpectedText 'Usage: noctty'
```

## cli-redirected-text-action.ps1

Runs a GUI-subsystem CLI action with redirected stdout/stderr and verifies
clean, bounded text-mode completion. Wired into `package-portable-cli.ps1`.

```powershell
pwsh -NoProfile -File .\cli-redirected-text-action.ps1 -Action +help -ExpectedText 'Usage: noctty'
```

## cli-detached-action.ps1

Validates that a CLI action launched with no console at all surfaces the native
CLI-failure dialog and exits 1 rather than failing silently, plus its timeout
behavior. The process under test is created through WMI so that it has no
console and no console-owning ancestor; a plain `Start-Process` would let the
action attach to the calling shell's console and succeed. WMI does not carry the
caller's environment, so `-ResourcesDir` is accepted but not propagated; the
assertion does not depend on it, because the action fails on output before it
would need its resources.

```powershell
pwsh -NoProfile -File .\cli-detached-action.ps1 -Action +version
```

## package-portable-cli.ps1

Packages or reuses a portable build, then runs shell, redirected-text, and
detached-action checks against the staged artifacts.

```powershell
pwsh -NoProfile -File .\package-portable-cli.ps1 -Version 0.0.1
```

## assert-interactive-runner.ps1

GitHub Actions preflight for the dedicated interactive Windows runner. It
checks OS/session/runner provenance and can write the evidence JSON path.

```powershell
pwsh -NoProfile -File .\assert-interactive-runner.ps1 -OutputPath .\runner-evidence.json
```

## powershell-shell-integration.ps1

Behavioural check for PowerShell shell-integration prompt hooks, OSC output, URI
escaping, feature flags, and cleanup. CI runs it under PowerShell 7 and Windows
PowerShell 5.1 with isolated PSReadLine history.

```powershell
pwsh -NoProfile -File .\powershell-shell-integration.ps1
```

Most of the script dot-sources `integration.ps1` at its own scope. The final
section instead spawns a child running noctty's real injected argv
(`-NoExit -Command "& { $__ghostty_utf8_console = $false; . <path> }"`) with a
`NOCTTYPROBE> ` prompt pre-installed, because the `& { }` child scope is where
scope-loss regressions like #231 show up and an in-scope dot-source cannot see
them. Worth running under `powershell.exe` (5.1) as well as `pwsh` (7):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\powershell-shell-integration.ps1
```

## interactive-win11-validate.ps1

Composite Win11 validator. It runs launch-helper checks and startup smoke,
then runs the command-finish and progress validators in parallel against
separate sandbox roots.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-validate.ps1 -ResetState
```

Pass `-Rebuild` to force one upfront `zig build -Demit-exe=true` before
the suite starts. The suite also does that upfront build automatically
when tracked inputs are newer than `zig-out\bin\noctty.exe`, so child
harnesses reuse one fresh binary instead of rebuilding in parallel.

## interactive-win11-smoke.ps1

Interactive Win11 startup smoke validation. It launches `noctty`
inside the repo-local Win11 sandbox and waits for shell startup to be
observed in stderr.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-smoke.ps1 -ResetState -TimeoutSeconds 10
```

## interactive-win11-command-finish.ps1

Interactive Win11 validation for command-finished notifications. It launches
`noctty` inside the repo-local Win11 sandbox, emits raw OSC `133;C`,
OSC `9;4`, and OSC `133;D;17`, and then validates that the
command-finished path fired.

- If Windows toast delivery is enabled for the current user, the script
  asserts the command-finished path completed without a WinRT toast
  failure.
- If Windows toast delivery is disabled for the current user or app, the
  script asserts the runtime logs the explicit
  `error.NotifierDisabled; falling back to banner` path instead of
  silently dropping the notification.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-command-finish.ps1 -ResetState -TimeoutSeconds 12
```

The harness rebuilds automatically when `build.zig`, `build.zig.zon`, or
files under `src\` are newer than `zig-out\bin\noctty.exe`. Pass
`-Rebuild` to force a full rebuild anyway.

## vt-probe-win32-conformance.ps1

Win32 VT protocol conformance metadata validation. It runs `+vt-probe` and
asserts that each capability reports a separate Win32-runtime
classification:

- `validated` means an interactive Win32 harness exercises the behavior.
- `parser-only` means shared parser/core support exists, but no Win32 GUI
  behavior is validated.
- `pending` means the Win32 behavior exists or is expected, but the practical
  harness is still missing.

Run the fast metadata check with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\vt-probe-win32-conformance.ps1 -ResetState -TimeoutSeconds 10
```

Pass `-Runtime` to also run the heavier Win32 evidence harnesses currently
referenced by `+vt-probe`: command finish / notification and taskbar
progress.

## interactive-win11-progress.ps1

Interactive Win11 validation for native progress state changes. It
launches `noctty` inside the repo-local Win11 sandbox, emits raw
OSC `9;4` state transitions for `set`, `pause`, `error`,
`indeterminate`, and `remove`, takes a screenshot of the `noctty` window
for each state, and fails if:

- the runtime logs `taskbar progress init failed`,
  `taskbar progress sync failed`, or a crash
- noctty exits, or the payload does not reach one of the states before
  the timeout

The script reports whether the `set`/`remove` and `pause`/`error`
screenshots differ (`unknown` when one was not saved). The comparison is
diagnostic only: hosted desktop environments do not always expose the
rendered window to screen capture. The screenshots go through the same
gate as the pixel diagnostic (see the interactive job below), so a state
whose screenshot would show anything but noctty logs why and saves none.
The harness takes no capture of the taskbar: a strip of the bottom of the
screen showed whatever the user had pinned and running there and was
never evidence of taskbar rendering.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-progress.ps1 -ResetState -TimeoutSeconds 20
```

## interactive-win11-shaders.ps1

Interactive Win11 validation for custom post-processing shaders. It builds
with `-Dcustom-shaders=true`, loads a deterministic solid-magenta ShaderToy
fixture, takes a screenshot of the terminal surface child window (through the
screenshot gate), and fails unless the dominant sampled surface color is
magenta. With `NOCTTY_INTERACTIVE_MEASURE_AUMID=1`
(the release job), `-Rebuild` rebuilds the measurement generation instead, which
always carries custom shaders.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-shaders.ps1 -Rebuild -ResetState
```

## interactive-win11-shader-pacing.ps1

Regression harness for #297. It runs an animated custom shader with
`power-saver-rendering = on` (the pacing Battery Saver or Energy Saver turns on),
types into the terminal with key messages sent to the surface over three rounds,
and fails unless each step's output reaches a presented frame within two
seconds, per the render trace's `last_swap_process_output_bytes`, and the
animation keeps presenting at the paced rate. The bug it guards against is
timing-dependent, so one run on a regressed build can still pass.
It needs an executable built with custom shaders, for example the one
`interactive-win11-shaders.ps1 -Rebuild` leaves behind, or the measurement
build in the release job.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-shader-pacing.ps1 -ResetState
```

## interactive-win11-resize.ps1

Interactive Win11 validation for resize repaint coverage. It launches
`noctty` with a light terminal background, synthesizes a live resize
growth, exits the resize loop, captures the settled enlarged window, and fails
if the newly exposed right or bottom content bands are mostly near-black or
unpainted neutral gray. Each capture is clipped to noctty's client area inset
by the corner radius, and the band check reads it in memory; it is saved to
the logs only through the screenshot gate (see the interactive job below).

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-resize.ps1 -ResetState -TimeoutSeconds 15
```

## interactive-win11-conpty-sync.ps1

Differential check that noctty's screen agrees with ConPTY's own buffer after
resizes, the search bar, splits, maximize, minimize and full-screen programs.
Each scenario starts a portable copy of noctty on a hidden desktop, puts cmd,
Windows PowerShell or pwsh into a known state, applies the trigger, and
compares noctty's visible rows (UIA `TextPattern`) with ConPTY's (a helper that
attaches to the shell's console and reads it with `ReadConsoleOutputW`), then
types a marker and compares again. It never takes the foreground or touches
the real profile, and it redirects PSReadLine's history (which ignores
`APPDATA`) into the sandbox.

Scenarios marked `Expect = 'desync'` are known bugs: they pass while they
still differ and fail once they stop, so the fix removes the mark. `-Scenario`
runs a subset and `-ListScenarios` lists them. Missing optional programs
(`pwsh.exe`, Git for Windows' `vim.exe`) skip their scenarios. The headless
counterpart is `src/terminal/resize_replay.zig`.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-conpty-sync.ps1 -ResetState
```

`.github/workflows/conpty-sync.yml` runs it with `-NoBuild -RequireAll` on a
hosted `windows-2025` runner (x64 only) for pushes to `main` and for pull
requests that touch the build inputs or the harness; it is not a required check.
It is not part of the interactive composite. The composite is dispatch-only, so
it never sees a pull request, and in measurement mode the harness asserts the
measurement build's `noctty.exe` but stages `zig-out\bin` (the product build, or
nothing), so it would test the wrong binary until that is changed.

On the runner the step sets `NOCTTY_INTERACTIVE_WIN11_CONPTY_SYNC_BOOTSTRAPPED=1`
and runs the harness under `powershell.exe`. The sentinel skips the relaunch
through `scripts\dev-windows.cmd` that the harness otherwise makes, which
`-NoBuild` does not need: it builds nothing. `-NoBuild` needs a build of this checkout in
`zig-out`. `-RequireAll` fails a scenario that is skipped because `pwsh.exe` or
vim is missing, which otherwise counts as a pass. The job uploads the scenarios'
text evidence (before, after and marker rows, `inner.log`, the results JSON) and
no screenshots.

Each step of a scenario's start logs a line (launched, host window, shell, first
prompt), and when the inner half has not finished within `-TimeoutSeconds` the
outer half prints a diagnostics block before it ends the run: the inner
process's tree with thread states and wait reasons, and the hidden desktop's
windows with Windows' hung flag (no command lines, titles or environment). That
block is how a hang in this harness was traced to its cause: the walk that finds
the shell under noctty followed `ParentProcessId` without noticing that Windows
reuses process numbers, found a cycle and spun at 100% CPU.
`flagship/contracts/Contracts.97-ConptySync.ps1` drives that walk, and the dump
reader's retry, with synthetic input.

## interactive-win11-ime-candidate.ps1

Interactive Win11 validation for IME candidate anchoring. It launches
`noctty`, scripts the terminal cursor to a non-origin row/column,
sends a synthetic mouse move near the surface origin to poison the old
mouse-derived path, triggers `WM_IME_STARTCOMPOSITION` on the surface
HWND, and reads the env-gated runtime trace for the composition/candidate
forms computed inside `positionImeWindow()`.

The harness verifies that the traced candidate form uses `CFS_EXCLUDE`,
shares the composition point, exposes a caret-height exclusion rect, and
lands near the scripted caret instead of the poisoned mouse coordinate. It
does not assert that Windows created an IME context or that a real IME
language pack renders a visible candidate popup; that remains
manual/IME-environment coverage.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-ime-candidate.ps1 -ResetState -TimeoutSeconds 18
```

## interactive-win11-undo.ps1

Interactive Win11 validation for the shipped undo/redo action set. It launches
`noctty`, exercises split creation, tab close/restore, and empty-host
survival after last-tab close, then verifies the visible tab/surface counts
after each replay step. Last-tab headless undo/redo remains covered by focused
Zig tests plus manual validation; this harness does not claim foreground
keyboard coverage.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-undo.ps1 -ResetState -TimeoutSeconds 35
```

## interactive-win11-palette-theme.ps1

Validates Universal Palette theme preview, Escape rollback, Enter commit and
config persistence, plus suppression of theme preview while Windows High
Contrast is active. High Contrast mutation is opt-in with
`-ExerciseHighContrast`; the harness serializes that phase and restores the
original system setting in `finally`. Before its first screen-pixel check it
proves that a fresh process presents the Dracula background (two attempts),
because the accessibility harness turns High Contrast off just before it in the
release job.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-palette-theme.ps1 -ResetState
```

## interactive-win11-issue149-colors.ps1

Validates issue #149 through the real default config discovery path and the
retained WGL presentation path. It first verifies foreground, background, and
palette index 1 through the public `+show-config --changes-only=false` API. It
then uses `PrintWindow` client-framebuffer readback rather than desktop
screenshots, and verifies default colors, bundled `Cobalt2`, explicit overrides
after the theme, live config reload, new-tab and new-split inheritance. The
configured payload paints independent bands for the default foreground and
palette index 1. `-MinimumDpi 144` makes a high-DPI run mandatory when that
desktop is available. Its config sets `unfocused-split-opacity = 1`: the
new-split phase reads both panes for the exact colors, and the pane that loses
focus to the new split would otherwise be dimmed.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-issue149-colors.ps1 -ResetState -MinimumDpi 144
```

The harness is intentionally red-capable: supplying a wrong literal such as
`-ExpectedThemeBackground 010203` must fail on the Cobalt2 framebuffer phase.

## interactive-win11-session-restore.ps1

Validates a three-tab session save/restart restore with the second tab selected,
then injects corrupt state and requires a fresh one-tab launch plus a uniquely
named quarantine artifact.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-session-restore.ps1 -ResetState
```

## hidden-win11-profile-matrix.ps1

Starts each shell profile noctty detects (`cmd.exe`, `powershell.exe`,
`pwsh.exe`, Git Bash) through a restored session on a hidden desktop and checks
what the profile really started: the process under noctty and a redacted shape of
its command line (the PowerShell injection, Git Bash's `--login -i`), and the
working directory the shell reports with OSC 7, read from the `session-state.json`
noctty saves at close. cmd and Git Bash are sent a directory change as posted keys;
PowerShell panes are never typed into. Their run-owned integration copy sets a
new run-local PSReadLine history path and `SaveNothing` before the first read;
a marker written after the actual integration prompt replaces a fixed delay.
Original and instrumented script hashes are retained. This instruments the test
copy for isolation/readiness and does not generate OSC 7 or alter cwd. Redirecting
`APPDATA` alone is not sufficient history isolation. The harness proves the real
history file, `startup-attempts.json` and the clipboard sequence number did not
change. A control case runs cmd with `shell-integration = none` and expects the seed to
survive. No interactive WSL or SSH profile is started; startup discovery may
probe WSL. A profile that is not installed is skipped and reported; `-RequireAll`
turns any such skip into a failure. The hosted workflow requires all four.

```powershell
pwsh -NoProfile -File .\hidden-win11-profile-matrix.ps1 -Bin <dir with noctty.exe> -Run <new dir>
```

The binary must carry the measurement AppUserModelID (the jump list is keyed by
AUMID in the real `%APPDATA%`, which redirection does not move) unless
`-AllowProductAumid` says the machine is an ephemeral runner. Results are in
`profile-matrix-results.json`.

The driver has no console, so it writes `profile-steps.jsonl`: one line as each
step starts (detecting a profile, copying a case, the launch, the process-tree
query, the prompt and typing, the close, reading the saved session, a forced
stop, the results). After a stall the last line names the step. The query, `Get-Descendants`
in `hidden-win11-lib.ps1`, has a 15 s deadline, and its walk keeps a child only
if the child is not older than its parent, and visits each process once:
Windows reuses process numbers, so a stale `ParentProcessId` can point at a
newer process, even one below it, and a walk without those rules found a cycle
in another harness and never returned. `flagship/contracts/Contracts.96-HiddenHarnesses.ps1`
drives the walk, and the same rule in `hidden-win11-default-shell.ps1`'s
`Find-Shell`, with a recycled-number process table.

## hidden-win11-embedding-idle.ps1

Ephemeral-runner lifecycle of `noctty.exe -Embedding`, the process Windows starts to hand
over a delegated console. It starts one with nothing to hand over, with
`LOCALAPPDATA` and the portable folder holding seeded `session-state.json`,
`palette-mru.txt`, `update-state.json`, `jump-list-recents.json`,
`startup-attempts.json` and `config.ghostty`, and checks that it opens no window
(other than the never-shown `noctty.win32.lifecycle` window every noctty process
makes so that Restart Manager can ask it to close, and the default IME windows
Windows gives its thread for it, all of which must stay hidden),
exits by itself after its five-second idle timer with code 0, leaves every seeded
file byte-identical, quarantines nothing and does not touch the console
delegation values. `-NegativeControl` starts an ordinary instance instead and
expects the window oracle to fire. It writes no delegation registry value and
delivers no handoff; journeys that need one need a machine that can be restored.
The workflow also runs that negative control with `-Renderer d3d11-warp` so
an ordinary instance can open a window on the GPU-less runner.
The harness refuses to start when the user's `DelegationTerminal` selects noctty:
the measurement AUMID does not isolate the session's live COM handoff class.
That check, `Assert-EmbeddingDelegationSafe`, has one copy,
`hidden-win11-embedding-guard.ps1`, which both `hidden-win11-lib.ps1` and
`hidden-win11-local-lib.ps1` dot-source, so `hidden-win11-restart-manager.ps1`'s
`embedding-idle` case refuses the same way. Contracts.96 pins the function and
both harnesses' calls with mutation controls.

```powershell
pwsh -NoProfile -File .\hidden-win11-embedding-idle.ps1 -Bin <dir with noctty.exe> -Run <new dir>
```

Both scripts currently require an ephemeral GitHub-hosted runner; local launches
are blocked until the exact bundled and in-box ConPTY desktop placement has
hosted evidence. The workflow supplies the runner environment and collects the
desktop metadata receipts and binary fingerprints with its artifacts.
`hidden-win11-desktop-control.ps1` is a hosted-only positive control: a harmless
window in a nested owned job must be detected from the outer job on Default.
It launches no noctty and stops its owned helpers after the check.

Both scripts share `hidden-win11-lib.ps1` (private desktop, owned job, explicit
desktop selection for harness launches, inherited desktop handles for direct
children, and real-state receipts). The parent validates the driver's desktop
self-report against its PID, job membership, window station and session, and
requires its known PID's hidden control window on the named private desktop before
approving app launch. The control window stays until app-job cleanup and the parent's final private-window
check acknowledge a bounded release handshake; Default checks continue through exit.
The outer process independently enumerates the named private
desktop and rejects job-owned top-level windows on Default, including hidden
windows. Profile readiness requires the known noctty PID's window on the private
desktop before posted input.

Server 2022 returned `GetThreadDesktop` error 5 (access denied) for live foreign
pwsh/conhost threads, even with matching WinSta0/session IDs and a fresh observer
thread attached to the private desktop. That is a hosted API observation, not
proof of a desktop escape. The window oracle uses documented `OpenDesktopW` and
`EnumDesktopWindows` instead of interpreting a denied query as safe.
A fresh empty desktop returned false/error 0 from `EnumDesktopWindows`, both
locally and on Server 2022. The known driver control window avoids relying on an
empty enumeration; false/error 0 remains a failure. The parent checks Default
while awaiting the driver's ready receipt and does not approve app launch until
the private-window observation succeeds.
Sampling does not establish desktop membership of windowless foreign threads or
prove the absence of a window whose whole lifetime falls between samples.
No external broker journey is exercised; keep bundled and in-box ConPTY
desktop evidence separate. The Server 2022 run is not a Windows 10 desktop pass.

## hidden-win11-local-lib.ps1

Shared by the hidden-desktop harnesses that run on a developer machine
(`hidden-win11-docked-search.ps1`, `-single-tab-close`, `-dpi-geometry`,
`-quick-terminal-identity`, `-session-restore`, `-default-shell`,
`-restore-quarantine`, `-app-delivery` and `-restart-manager`); each dot-sources it and still runs on
its own. It holds the private desktop, the owned kill-on-close job, the two
explicit-desktop launches (`Launch` for the driver, `Spawn` for a case),
`Invoke-LocalHiddenDriver` (the outer half: run the harness again as its driver
on a new private desktop with LOCALAPPDATA and APPDATA redirected into the run
directory, then check the real `startup-attempts.json`, PowerShell history
metadata, and, where the harness asks, the clipboard sequence number), the
small helpers those harnesses had copied, and, from `hidden-win11-embedding-guard.ps1`,
the `-Embedding` delegation guard.

## PowerShell history isolation

`scripts/windows-harness-history.ps1` resolves the real history paths through
Windows known folders and compares only existence, size and UTC mtime. Interactive
entry points start the guard before launching and assert it in `finally`; the
composite also guards the whole batch. A change fails with the harness name,
including when another check already failed. The guard never opens or hashes
history. Maintainer activity during a run can also trip it and must be attributed
before another launch.

Shell-independent panes use `--command=cmd.exe`. An explicit `-e` selects only
the first pane, so additional tabs and splits still need the cmd default.
Only fixtures that test a configured `command` opt out of the shared pin.
Tests that need interactive
PowerShell configure PSReadLine before the first read, using a run-local
`HistorySavePath` and/or `HistorySaveStyle SaveNothing`. Redirecting `APPDATA`
alone does not isolate PSReadLine. Seeded prediction tests retain their scratch
history with `SaveAtExit`. `harness-history-guard.ps1` checks the guard against
scratch metadata changes and real PSReadLine writes on a private desktop;
the negative control must reject the scratch write and the isolated control
must leave its scratch history unchanged.

The interactive composite builds exact clean `HEAD` in a generation under
`.sandbox/interactive-measure/<HEAD>`, with only the recorded measurement AUMID
patch applied to extracted source. It suppresses product registration writes and
uses `.measure` for process and jump-list identity. The explicit product toast
notifier and command-finish policy stay unchanged. Source/build receipts bind
the source archive, patch and both executable hashes; the composite retains and
rechecks them. This is measurement-build evidence, with registration repair and
installed cold-start activation outside its coverage. Each child retains its
own redirected config directories. See [history-inventory.md](history-inventory.md)
for the shell and guard used by each harness. The measurement build carries
custom shaders (`-Dcustom-shaders=true`, as releases do) and its receipt binds
the exact build arguments.

`interactive-win11-job.ps1` is the Test workflow's `windows-interactive` job:
the composite, then the shader, shader-pacing, accessibility, palette-theme and
session-restore leaves, all with `NOCTTY_INTERACTIVE_MEASURE_AUMID=1`, so every
launch uses the composite's measurement build and none rewrites the product
jump list (the Shell keeps one per AUMID in the real profile, which a redirected
`APPDATA` does not move). One state guard spans the whole job: a change to the
product jump list, the real `startup-attempts.json` or the clipboard sequence
fails it, and its receipts go to `flagship/artifacts/interactive-win11/job-state`.

When a screen-pixel wait (`Get-StatefulPixel` inside `Wait-InteractiveWin11Until`)
times out, the harness writes `pixel-diagnostic-*.json` to its sandbox `logs`
folder, which the job uploads: the window under each of the 16 sample points
(handle, class, process name; never a title) and the color read there, the
foreground window, whether noctty's window was hung, cloaked, minimized, hidden
or see-through, the input idle time, the windows above it that overlap the
rect, and a screenshot of the sampled rect. The screenshot is taken only while
noctty's window is shown, uncloaked, not minimized and opaque, every sample
point lies on a noctty window, and no window of another process above it
overlaps the rect (unless DWM says that window is cloaked); it is clipped to
noctty's client area inset by the corner radius, and written only if the same
check still holds right after the capture (`Get-StatefulScreenshotDecision`).
Otherwise the report says why it was withheld. The 16 single-pixel colors are
recorded either way, so a sample point on another application's window records
that window's color at that point.

Every other screenshot the job uploads (progress, resize, shaders) is saved
through the same gate, `Save-StatefulScreenCapture` in
`interactive-win11-stateful-lib.ps1`. A verification contract fails when a
harness, script or workflow uses `CopyFromScreen` for more than one pixel
outside it, and when any harness but resize asks it for the in-memory image
(`-PassThru`, which is not gated). The only other files allowed a capture are
`interactive-win11-shell-command-live.ps1`, which keeps its captures in the
sandbox `temp` folder that no workflow uploads, and the maintainer's opt-in
`renderer/Invoke-VisibleD3D11Check.ps1`.

## ..\..\scripts\check-test-skips.ps1

Budget for the Zig tests that skip themselves. `zig build test` reports only a
total, so a font-shaping test that starts skipping on a runner looks like one that
always did. The script reads the per-test output of `ghostty-test.exe` run
directly and fails when a test in the guarded family (`font.`) skips and is
not on the runner's allowlist in `test-skip-budget.json`, when the total is above
the runner's budget, or when the log is incomplete.
The `windows-2022` ceiling of 76 and its nine font skip names were measured from
run [39027272717](https://github.com/amanthanvi/noctty/actions/runs/39027272717).
`-Report` drafts an allowlist for a new runner, but still rejects incomplete,
inconsistent or failed output. CI runs without `-Report` to enforce the budget.

```powershell
zig build -Demit-test-exe=true -Dcustom-shaders=true
.\zig-out\bin\ghostty-test.exe *> ghostty-test.log
pwsh -NoProfile -File ..\..\scripts\check-test-skips.ps1 -TestLog ghostty-test.log -Runner windows-2022
```

## ..\..\scripts\interactive-win11.ps1

Generic repo-local Win11 launcher for ad hoc debugging. It uses the
same sandbox setup logic as the focused harnesses and can either
launch `noctty` directly or open a shell with the sandbox
environment applied.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ..\..\scripts\interactive-win11.ps1 -ResetState
```

## interactive-win11-stale-modes.ps1

Checks that cmd and PowerShell recover Enter and Ctrl+C after a program leaves
Kitty keyboard or modifyOtherKeys modes enabled, on normal exit and exact-PID
termination. `-Scenario Modes` uses hidden desktops and never accesses the
clipboard. Use a measurement-AUMID build on a shared machine; the harness copies
it into fresh portable directories, redirects AppData, and uses a unique class.

```powershell
pwsh -NoProfile -File test/windows/interactive-win11-stale-modes.ps1 `
    -ExePath <measurement-build>/zig-out/bin/noctty.exe -Scenario Modes `
    -Shells cmd -ExerciseInheritedCtrlCIgnore
```

`-ExerciseInheritedCtrlCIgnore` starts the hidden worker with
`CREATE_NEW_PROCESS_GROUP`, which disables Ctrl+C through an inheritable Windows
process attribute. The hidden controller explicitly enables Ctrl+C with
`SetConsoleCtrlHandler(NULL, FALSE)` before launching noctty. Registering the
fixture's `Console.CancelKeyPress` handler alone does not clear that attribute.
Without the controller reset, the cmd regression times out at
`31-exit.ctrl.interrupted`; a native input observer confirmed that the Ctrl+C
record still reaches ConPTY's input in this condition.
Removing the controller reset must fail this invocation. The fixture itself
never clears the attribute, so it can still detect an ignore flag introduced by
the product's own launch path.

See Microsoft's [SetConsoleCtrlHandler documentation](https://learn.microsoft.com/en-us/windows/console/setconsolectrlhandler)
for the inherited attribute and [start command reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/start)
for `/b`'s corresponding Ctrl+C behavior.

The inherited-ignore exercise requires `Modes` or `All`; `Paste` alone is rejected.
The ordinary invocation omits the regression switch. `-Shells cmd` restricts it
to cmd; the default tests both shells. `-Scenario Paste` and `All` additionally
use a private window station because desktops on WinSta0 share the clipboard.

## Style

- Define reusable helpers as `function Verb-Noun { ... }` with a `param(...)`
  block and typed, PascalCase parameters where practical.
- Resolve `$repoRoot` once, then dot-source shared code with
  `. (Join-Path $repoRoot 'scripts\name.ps1')`.
- Aim for roughly 120 columns. Wrap multi-parameter invocations with splatting
  or aligned continuations; keep indivisible diagnostic strings and pinned
  regular expressions intact.

## test_dll_init.c

Packaged libghostty-vt smoke. Loads an explicit ghostty-vt.dll path and calls
ghostty_build_info, ghostty_osc_new, and ghostty_osc_free to verify export and
allocator initialization. The portable package CLI smoke compiles and runs it.

### Build

From the repository root, build libghostty-vt and compile the test:

```powershell
zig build -Demit-lib-vt=true
zig cc test/windows/test_dll_init.c -I include -lshell32 -o test_dll_init.exe
```

### Run

Pass the absolute path of the built or packaged DLL:

```powershell
.\test_dll_init.exe (Resolve-Path .\zig-out\bin\ghostty-vt.dll).Path
```

Expected output:

```text
libghostty-vt DLL smoke: 3/3 checks passed (version=<version string>)
```

The OSC parser allocation and free exercise the DLL's C runtime. Missing
exports, failed allocation, or an empty version fail the smoke.
