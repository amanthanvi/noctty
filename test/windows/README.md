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
separate sandbox roots. `-DeferCommandFinish` leaves the command-finish
validator out (the suite logs it as deferred, and its coverage line says the
caller checks the command-finish policy) for a caller that runs it later, as
`interactive-win11-job.ps1` does.

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

With delivery enabled it raises a real toast, on the visible desktop even
when noctty runs on a private one, and the banner can cover or take the
foreground from a later harness. Run nothing that reads screen pixels or
needs the foreground while that banner is up; the release evidence job runs
this leaf last for that reason.

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
(`pwsh.exe`, Git for Windows' `vim.exe`) skip their scenarios, and so does the
Clink scenario without `-Clink <extracted portable Clink>\clink_x64.exe`; that
folder is copied into the sandbox and injected into cmd with a profile of its
own (an empty `.inputrc`, an empty `--scripts` folder, `clink.autostart = nul`
so no `clink_start.cmd` runs, and every inherited `CLINK_*` override removed). It is also skipped while script folders are
registered with `clink installscripts`, which would load into it. Every cmd
scenario starts `cmd.exe /d` with `CLINK_NOAUTORUN=1`, so a Clink installed for
AutoRun stays out. The headless counterpart is
`src/terminal/resize_replay.zig`.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-conpty-sync.ps1 -ResetState
```

`.github/workflows/conpty-sync.yml` runs it with `-NoBuild -RequireAll` and the
portable Clink 1.9.34 `test.yml` checks (same checksum) on a
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

## hidden-win11-conpty-reply-path.ps1

Which terminal replies reach a console program through ConPTY's input, and in
what shape (the kitty report's shortlist #0; log entry REPLY-PATH-01 in
`docs/agents/log/conpty.md`). On a private desktop, a portable copy of noctty
(without `noctty.ico`, with its own AppData, clipboard reads and writes denied,
and later tabs on `direct:<System32>\cmd.exe /D` so no cmd AutoRun runs in the
run; the helper compile's `dev-windows.cmd` still runs it, and an fnm hook's
junctions from it land in your own `%LOCALAPPDATA%\fnm_multishells`) runs
`console-reply-reader.c` as
its `-e` child in one reader state at a time, types keys so conhost has seen
Win32 input mode records, then has noctty write each case's reply: its own
answers to the reader's queries, and `text:` bindings with the exact bytes,
a split as two writes. Case 7 injects the same shapes at a PSReadLine prompt
with its history isolated. Results go to `results.json` and `results.md` in
the run directory, each row observed against the source's prediction.

```powershell
pwsh -NoProfile -File .\hidden-win11-conpty-reply-path.ps1 -Bin ..\..\zig-out\bin -Run <new dir>
pwsh -NoProfile -File .\hidden-win11-conpty-reply-path.ps1 -Bin ..\..\zig-out\bin -Run <new dir> `
    -Readers a,a16,b,c,c-inbox,d,d-notiming -AllowSshFarSideUserProfileAndLocalAppData
```

The default readers are a, a16, b and c, all behind the bundled ConPTY.
c-inbox puts reader c behind the in-box conhost. d and d-notiming run System32's
`ssh.exe` to a one-connection `sshd.exe -d` on 127.0.0.1, run as you with keys
made for the run and deleted after it, forwarding off on both ends;
d-notiming adds `-o ObscureKeystrokeTiming=no`. Their far side runs through
sshd's `DefaultShell` (`HKLM\SOFTWARE\OpenSSH`; `cmd.exe` when unset) as you,
with your real `LOCALAPPDATA`, and a PowerShell `DefaultShell` also loads your
own PowerShell profile. So they run only with
`-AllowSshFarSideUserProfileAndLocalAppData`, and only with a Run path of
letters, digits, `_`, `.`, `-` and `\`, since the far side's shell gets the
reader command unquoted.

The Run directory must be new. The harness makes it with a protected ACL (you,
SYSTEM and Administrators, inherited by everything in it) and reads that back
before it writes anything there. That ACL is defence in depth for Run's own
contents. It does not guard against an account with rights on Run's parent
folders: other local accounts are outside the harness's threat model, since it
runs under your own account on a single-user machine. It refuses to run with
`NOCTTY_CONPTY` already set, since it sets that itself for c-inbox.

Exit 0 means every requested reader ran every step, case 7 ran with its
controls (unless `-SkipPSReadLine`), and every positive control came back as
predicted; other rows are observations, recorded either way, and a row whose
step never finished reads INCOMPLETE. Exit 1 is an incomplete run, a failed
control, a reader in the wrong state or without a clean stop, or a case 7
without a prompt row before and after its tab switch; 2 infrastructure, in the
driver or the outer phase (an inherited `NOCTTY_CONPTY`, or a Run whose ACL
does not read back as yours alone); 3 a changed isolation guard (the startup ledger, the PowerShell
history, the product AUMID's registration, the clipboard sequence number), a
link left in the run directory, or an ssh secret that could not be deleted.

Controls: `-Sabotage delimiter|reader|control` breaks one thing on purpose and
must exit 1. `-Sabotage setup` fails the setup at the point where reader d's
ssh keys already exist, and must exit 2 with any keys deleted (with no ssh
reader there are none to make). `-Sabotage key` holds an ssh secret's file open
through the cleanup, and must exit 3 with the guards compared and the failure
recorded. `-Sabotage acl` gives Everyone a rule on the Run directory once it is
made, and must exit 2 with nothing compiled or launched.

`flagship/contracts/Contracts.98-ConptyReplyPath.ps1` holds the harness to its
safety and measurement properties in two ways:

- **Checks and mutations.** It checks each launch's desktop and job, the
  isolation flags and guards, the bindings' bytes, the step plan, the
  predictions, the verdicts and the exit policy. It then applies 149 mutations
  (the council's from rounds 1 to 6, the review bots', and its own). Each must
  be refused by the whole-file pin and by the pin of every pinned region or
  function it changes. All but the 39 marked `PinOnly` must also be refused
  with the pins skipped (`-SkipPins`), so each of those mutations is shown to
  be refused by a content check too; that does not show every content check
  is exercised. The 39 are edits only a pin can see, and they must get nothing
  from the content checks, so the mark stays true. A mutation with `Check`
  must be refused by that content check itself.
- **A closed set of pins.** The whole harness and the whole reader are pinned
  by SHA-256 with LF line ends. Any edit to either fails the contract until its
  pin there is updated in the same change, so a reviewer sees it. The regions
  between `# pin-begin:` and `# pin-end:` comments in the harness (the reader
  list, the whole outer phase, case 7, the driver's results) and the functions
  the contract lists are pinned as well, only so that a failure names the
  block that changed. Not pinned, since other harnesses share them:
  `console-attach-info.c` (case 7's prompt reader),
  `scripts\windows-harness-history.ps1` (its guard decides exit 3's history
  branch) and `scripts\dev-windows.cmd` (the helper compile, exit 2).

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

## hidden-win11-list-profiles.ps1

Runs `noctty.com +list-profiles` from a portable copy on a hidden desktop and
checks the profile list it prints: the profiles of a fixture configuration (two
`profile-order` entries first, one `profile-hidden` entry last), the detected
shells and SSH hosts after them, the fields of each line, `--plain` equal to the
redirected default, `--format=json` equal in order to the text, a bad argument
exiting 1 with nothing on stdout, and none of the fixture's command line,
variable or working directory in any output, as text or as the decimal or hex
list of numbers a byte string prints as. One run has `GHOSTTY_LOG=stderr`, which
switches the log that actions turn off back on, with a default profile and an
explicit `working-directory = home` so the log line that names the command is
reached: its stderr must say how big the command was (`<2 args, 32 bytes>`) and
not what it was. A last run has a `theme = light:A,dark:B` whose files hide different shells, and must list
the one for the scheme Windows reports for apps (read from the registry, never written). The fixture's `PATH` holds no
`wsl.exe`, so discovery never starts WSL, and its Visual Studio profiles are
off, so the result does not depend on the machine. The aligned table needs a
console and is covered by the unit tests. A CLI action returns before the app
creates a window, an AppUserModelID or a jump list, so any build works. The
harness proves the real `startup-attempts.json`, the PowerShell history files'
metadata and the clipboard sequence number did not change.

```powershell
pwsh -NoProfile -File .\hidden-win11-list-profiles.ps1 -Bin <dir with noctty.exe and noctty.com> -Run <new dir>
```

Results are in `results.json` and `checks.txt`; the output of each run is in
`<name>.out.txt` and `<name>.err.txt`.

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
`-restore-quarantine`, `-app-delivery`, `-restart-manager` and `-list-profiles`, the soak,
`interactive-win11-soak.ps1`, for its desktop, job and driver launch, and `hidden-win11-working-set.ps1`
for its desktop and guards); each dot-sources it and still runs on
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
the composite (with `-DeferCommandFinish`), then the shader, shader-pacing,
accessibility, palette-theme and session-restore leaves, and last the
command-finish leaf, the one step that raises a real toast, so that its banner
has no later leaf to disturb. No earlier step can run that leaf: only the plan,
the composite's guarded launch and `vt-probe-win32-conformance.ps1`'s
`-Runtime` branch, which no job script takes, name it. The accessibility
leaf's two processes that save Settings run with `--app-notifications=false`
and `--desktop-notifications=false` as the last notification values on their
command lines (no empty value of either after them, which would reset it to
its default, and no `--config-file`, whose include noctty reads after the
command line), so a save shows its in-window banner and no toast. The banner
needs a terminal window: with none open, `settingsNotifySuccessThunk` toasts
whatever `config-reload` says (`showHostBanner` finds no surface). Each saving
process keeps its own terminal window open through its save, and the leaf
checks that window right before each save.

Three layers keep those launches quiet.

- **Run-time checks, in the leaf.** Right after each saving launch, before its
  probe opens, `Assert-AccessibilitySaveLaunchQuiet` reads that process's own
  command line (only that process, by its id; it never prints or logs it),
  reads it with `Get-AccessibilitySaveLaunchVerdict` (last value wins, an empty
  value resets a setting to its default, `--config-file`, a quote and any
  character outside printable ASCII after the program name are refused), and
  stops the leaf unless desktop notifications, the clipboard-copy notice and
  config-reload notifications are all off. Before the first launch, before
  each save and before the verifier starts, `Assert-AccessibilitySaveSandboxQuiet`
  finds no default config file but noctty's own `config.ghostty` in the
  directory the saving environment's `XDG_CONFIG_HOME` names, and no
  `config-file` key in it, its lines read as noctty's `LineIterator` reads them
  (any other byte, such as the template's path in its comments, does not
  matter); before each save it also stops the leaf if the saving process's
  terminal window has closed, and before each launch if the build's own
  folder holds a portable marker (`noctty.portable`, `portable.txt` or
  `config.ghostty`, `portable_marker_names` in `src/os/xdg.zig`), which would
  make noctty read its config there whatever the environment says. Each save
  is the statement right after its last check: the probe's close prompt
  button is found first (`Get-AccessibilitySettingsCloseActionInvoke`) and
  pressed after the check. The launcher refuses an environment that names one
  variable twice in two cases. Both compare ordinally, as noctty compares bytes:
  PowerShell's `-eq` family ignores some characters (a soft hyphen; under
  PowerShell 7, ASCII controls), so `-ceq` read `fa`U+00AD`lse` as `false`,
  where noctty keeps the default on (the Zig test "a command line's
  notification flags are read byte for byte" in `src/config/Config.zig` is the
  reference).
- **Pins.** The leaf's regions between `# pin-begin: <name>` and `# pin-end:
  <name>` lines (`save-functions`, `save-sandbox`, `save-flow` and
  `failure-path`, the main catch through the final throw) are pinned in
  `flagship/contracts/Contracts.90-Workflows.ps1` by SHA-256 with LF line ends.
  An edit inside one fails that contract until its pin there is updated in the
  same change; the failure names the region and its new hash. Each region must
  hold the statements it guards.
- **Static grammar.** The same contract checks those two launches against a
  grammar, which names what changed. It refuses every form it does not list.

What none of the three sees: an edit outside every region that acts on its
own before the last check runs (an unpinned helper the flow calls first, such
as `Wait-AccessibilityCondition`, pressing Save itself, or an asynchronous
event handler registered elsewhere), or after a save's `Invoke()` returns,
while noctty is still saving and reloading (UI Automation's `Invoke` does not
wait for the click, and the wait after it is unpinned); a function whose name
itself carries the module qualifier (`function
Microsoft.PowerShell.Management\Start-Process`, which PowerShell then runs for
that qualified call); and a name built at run time that replaces a checker. An
include such a helper writes before the last check is still refused at run
time.

The contract runs the leaf's reading on synthetic command lines under
PowerShell 7 and Windows PowerShell 5.1, the run-time check against a stand-in
process lookup and the sandbox check on scratch directories. Its controls run
the grammar on the leaf less what the saves never touch (the other functions
and checks are cut; the pinned regions are kept byte for byte).

The grammar: the flags are one literal array of single-quoted strings, assigned
exactly once as `$name = @('...', '...')` or `$name = '...', '...'`. Each
launch's `-ArgumentList` is a variable assigned once as `$name = @( ... )`,
each element one of `Get-InteractiveWin11ContainmentArguments` with no argument
(defined once, in `scripts/interactive-win11-lib.ps1` and in no other job
script, as `return @( ... )` of single-quoted strings), a single-quoted string,
`"--class=$name"` with `$name = "<letters, digits, hyphens>$([Guid]::NewGuid().ToString('N'))"`,
or the flags variable. Each process a save runs in is assigned once, from its
launch, and each probe once, from that process. Every one of those variables is
written only by that one plain assignment and named nowhere else: no scoped
spelling, other assignment, index, member, `[ref]`, loop or parameter of that
name, no `-OutVariable`, `-PipelineVariable` or `Set-Variable` naming it, and no
other job script naming it. The three arrays are read only where the grammar
puts them, and `$settingsProbeEnvironment` only by the two launches and the
four sandbox checks, so no alias, method call or parameter reaches them. The
leaf's five save functions are each defined once, under no scope prefix, and in
no other job script. The leaf uses no variable or alias cmdlet,
`Invoke-Expression`, common variable parameter, `$ExecutionContext` or
background pipeline, and its code outside comments is printable ASCII. No job
script uses a variable or alias cmdlet (by any module-qualified name too),
`Import-Alias`, `Invoke-Expression`, a `function:`, `variable:` or `alias:`
drive, a `data` section, `[scriptblock]::Create`, `SessionState`,
`SessionStateProxy`, `$PSCmdlet`, `$PSDefaultParameterValues`, a function named
like a cmdlet the regions call (by its bare name), or `&`/`.` on a name built
by an expression.
The regions call `Start-Process` and `Join-Path` by their module, and nothing
but the cmdlets the contract lists and functions the job scripts define. No
`finally` block of the leaf, nor any function one calls, can end it before its
final throw. None holds an `exit`; a static `Exit` on any type, however the
type is written (`[Environment]::Exit(...)`, `([Environment])::Exit(...)`,
`$e::Exit(...)`), or a `$Host.SetShouldExit(...)`, called or not, the member's
name quoted or not; or a `break` or `continue` outside a loop of its own script
block. The flow statements inside the finally blocks are pinned one by one.
The check does not see a member named at run time (`[Environment]::$name(0)`)
or `ForEach-Object SetShouldExit`, which names the method as a command
argument.
Every statement of the save flow (the flags, class names and arrays, both
launches and their run-time checks, the probes, both saves and the four
sandbox checks) is a direct statement of the one block that holds the
launches, in order, each save the statement right after its last check, with
`-EnvironmentVariables $settingsProbeEnvironment` on
both launches. The arguments those forms give are printable ASCII with no
space, quote or backtick and no `--config-file`, and leave every notification
setting off.

The job's steps all run with `NOCTTY_INTERACTIVE_MEASURE_AUMID=1`, so every
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

## interactive-win11-soak.ps1

The soak (`PLAN.md` §3.5): one portable copy on a private desktop for
`-Minutes`, with its own job, `LOCALAPPDATA` and class (with
`--single-instance=false` there is no IPC pipe at all: neither server nor
client starts), started
through `Get-InteractiveWin11LaunchArguments` after its build mode is checked
through `+version`. Its shells are `direct:<System32>\cmd.exe /D` (no cmd
AutoRun), the clipboard is denied, the copy carries no `noctty.ico`, and it
starts with `SEM_NOGPFAULTERRORBOX` inside a job that ends a process on an
unhandled exception, so WER's dialog cannot hold a crash even after the
process's own error mode changes. Each minute it posts the churn keys (new
tabs, right and down splits, output floods through cmd, window resizes, pane
and tab closes; the first and every tenth minute stay idle), each bound under
every Shift, Ctrl and Alt chord so a modifier held at the real keyboard cannot
turn a posted key into an unbound one, returns the copy to one tab with one
pane, and samples it through the handle it
holds from `CreateProcess`: PID and creation time, whether the window answers
`WM_NULL` within 5 s, handles, threads (start address and name), private bytes,
working set, commit charge, GDI and USER objects, and the panes' other
processes. After the last minute it posts `WM_CLOSE` to each window the copy
still owns and takes the exit code from `GetExitCodeProcess`; it records a
clean quit only when a post took and the exit followed it. It then copies the
copy's crash files and any WER report
or Application Error event naming its path into `crash\`.

```powershell
pwsh -NoProfile -File test/windows/interactive-win11-soak.ps1 `
    -Bin <extracted portable ZIP>\noctty -Run <new dir> `
    -ExpectedBuildMode ReleaseFast -Minutes 480 -SandboxName soak-fast
python -I ci/soak_judge.py <run dir> --min-minutes 480 --other-run <the other copy's run dir>
```

Release coverage runs 480 minutes; Phase 0a's runs are 120 (`-Minutes 120`,
`--min-minutes 120`).

`ci/soak_judge.py` fails a run by the process rules (a gone, changed or hung
process, an early or non-zero end, an exit no quit request of the harness
reached (`UNASKED-EXIT`: an `end unasked` row, which fails even at exit code
0), a crash file, WER not suppressed, incomplete
or duplicated records, a short plan, a class not of the helper's shape or
shared with the other copy) and by the slope check: "no upward slope after
warm-up", a metric failing when its least-squares slope over the minutes after
the warm-up rises with confidence (its lower bound, slope minus 3 standard
errors, above the metric's floor in `ci/soak-thresholds.tsv`), and bounds on
threads by count and by kind. The warm-up is 60 minutes, measured: a clean
copy's heap grows under the churn for about an hour and then holds flat, so
the shortest run the judge accepts is 120 minutes (warm-up plus a 60-minute
window); a shorter `--min-minutes` is refused. A 120-minute run sees only a
fast leak (about 12 MiB/h and up on the clean 4-hour run's noise); 8 hours
hold one to the 4 MiB/h floor.
`-InjectHandleEachMinute` (one duplicated handle a minute) and
`-KillAtMinute 5` (`TerminateProcess` with exit code 3) are its first two
controls; `-HangAtMinute N -HangAt resize|sample` (the copy's UI thread
suspended for `-HangSeconds`, right after a resize or 10 s before a sample) are
the other two. The judge must fail all four. A resize hang needs a churn
minute, so `-HangAt resize` on the first or a tenth minute is refused, and a
hang must outlast its minute's sample (`-HangSeconds` at least 20 with `sample`,
100 with `resize`). Since a control never reaches the judge's records, a control
that did not take effect fails the harness itself (`ControlMisses` in
`harness.json`); a hang counts only when its minute's own sample saw the copy
fail to answer. Each minute's probe (liveness, the windows, their `WM_NULL`
answers) is timed where it runs, and `timing.tsv` keeps its start and end: a
probe that starts more than 5 s after its due time, or ends more than 5 s plus
the 5 s response bound after it, fails `LATE-SAMPLE`; one that starts before it
fails `EARLY-SAMPLE`; times that do not increase are `MALFORMED`. The driver
never waits on the copy without a bound. `ci/test_soak_judge.py` holds the judge's controls
and runs in the checks job; Contracts.98 pins the harness.

## gui-hosted-probe.ps1

A record-only diagnostic: it measures, and nothing gates on it. It shows where
noctty's processes and windows land, and what a GitHub-hosted runner's own
interactive desktop allows a GUI test. It runs from
`.github/workflows/gui-probe.yml`, which only `workflow_dispatch` starts, on
two builds of the same source, both prepared before the run. Q0 runs the
measurement build (`Invoke-InteractiveWin11MeasureBuild`). On a hosted runner,
P3 to P5 run a `-Drenderer-test-tools=true` build (`-TestToolsBin`) on both
desktops: one build and one fixture.

Every copy uses #727's launch policy:

- a portable copy without `noctty.ico`, with its own `LOCALAPPDATA` and
  `APPDATA`;
- every shell `direct:<System32>\cmd.exe /D`;
- the clipboard read and write denied, and `copy-on-select = false`;
- `renderer = d3d11-warp` and a seeded background (#1f6f8b).

These settings, the shell among them, go in the copy's portable
`config.ghostty`. The command line carries only the launch helper's isolation:
a shell passed there would travel as one argument with a space in it, which a
caller that splits arguments can cut before `/D`. Each run records the policy
as named fields. It also reads its shell's real command line by PID, and
records, never the text, that the shell is System32's `cmd.exe` with `/D`
ahead of any payload. Staging copies the build the way #727's soak does,
and refuses the run unless both the app (`noctty.exe`) and the CLI
(`noctty.com`) match the build: the measurement receipt's `ExeSHA256` and
`CliSHA256`, or the test-tools prefix's own files.
Nothing in a run builds or runs `dev-windows.cmd` or `cmd /c`.

**The launcher's gate.** `Get-ProbeLaunchRefusal` runs before every noctty
start, in measurement mode (`NOCTTY_INTERACTIVE_MEASURE_AUMID=1`, which the
probe sets for itself and its drivers). It allows only a portable copy (`noctty.portable` beside it, no
`noctty.ico`, the profile folders under `-Work`) of two builds:

- the receipt-bound measurement build;
- on a hosted runner only, the test-tools build.

A stock build shares the product AUMID and can rewrite the installed app's
per-user registration (app-lifecycle.md 2026-10-16), so locally only the
measurement build starts. The gate's control runs first and starts nothing.
It must refuse each of these for its own reason:

- a copy without the marker;
- a copy with the icon;
- another binary;
- the test-tools build off a hosted runner;
- an unredirected `LOCALAPPDATA`;
- measurement mode unset;
- a missing or mismatched `noctty.com` beside the app.

**Q0**, run locally and hosted, in three arms (design §9: "the CLI, either
ConPTY host"):

- the copy with its bundled ConPTY host (`OpenConsole.exe`);
- the same with the in-box host (`NOCTTY_CONPTY=inbox`, `conhost.exe`);
- the copy's CLI as PR 1's leaves run it: `noctty.com +version`, and
  `+list-windows --class=<fresh class> --format=json --timeout=1000`. The
  single-instance pipe is named only from `--class`, so the CLI arm reaches
  no other noctty, and it runs locally too. Its tree is sampled at every poll
  until the tree is done, and so are its windows: the same two-desktop
  inventory, with its sentinel and Default > 0 control, over the tree's
  processes. The walk keeps only the census's windows, so after it the job's
  members are read again: a member outside the census (it joined during the
  poll) that owns a window the walk dropped, on any desktop but the private
  one, is recorded as a job window there (`late-joiner`), and the arm cannot
  pass. A late joiner with no such window is only counted
  (`lateJoinersAfterWalk`); the GUI arms do the same. The probe starts
  `noctty.com` with
  `CREATE_NO_WINDOW`, so this arm does not test whether a console window
  would reach Default. Each invocation runs in a job of the driver's own,
  watched on a completion port, and each process that joins it (the forwarded
  `noctty.exe`, its console host) is read when the job reports it. The reader
  opens first: while a message waits it opens that process at once, and it
  reads one opened process only when none waits, on a thread above normal
  priority (test-harnesses.md 2026-11-20 PROBE-JOB-WATCH-OPEN-FIRST-01). That
  read is best effort. Windows does not guarantee `JOB_OBJECT_MSG_NEW_PROCESS`,
  a child can exit before it is opened (counted as `unopenedJoins`), and a PID
  is recorded only when the process opened is a member of the job created no
  later than the message was taken (else it is `unpinned` and left unread). A
  fault on the reader ends the reading, not the driver (`watchFaulted`). These
  counts are recorded only; what gates is `notSeenInJob`. A process that exits between
  polls but was read at its report keeps its startup desktop, which is then
  its only evidence: its row is `sampledAlive: false`, as its threads were
  never read. The arm is inconclusive unless:
  - every process the job counted was read (`notSeenInJob` 0);
  - every startup desktop was read;
  - each tree drained in time and the poll after the drain ran
    (`treeDoneInTime`);
  - each watched job closed (no `watchJobCloseFailed`).

Each arm:

- A driver created by name on a private desktop (`Invoke-LocalHiddenDriver`)
  starts the copy.
- It records the desktop of every process in the job, plus every descendant
  of the launched root whose link was verified on pinned handles. Each
  candidate is opened first, and its parent is read from the process itself,
  its creation time from the same handle, with every ancestor's handle held.
  A descendant outside the job is `leftJob`: it is judged like the rest and
  stopped by its exact PID and creation time. A link that cannot be verified
  is counted, never stopped.
- The bundled arm must see the copy's own `OpenConsole.exe`; a fall back to
  System32's `conhost.exe` fails it. The in-box arm must see `conhost.exe`.
- It reads each process's startup desktop (PEB `DesktopInfo`, taken as an
  offset into the parameter block until the child's loader normalizes it) and
  its threads' desktops while holding read-only handles to Default and the
  private desktop. A startup desktop that could not be read is recorded as
  `none`, the same as an empty name (PowerShell binds a null to `[string]` as
  an empty string); every gate treats `none` and `unreadable` alike, as
  unresolved. `GetThreadDesktop` names another process's thread desktop
  only while the caller holds a handle to that desktop (test-harnesses.md
  2026-11-20 PROBE-THREAD-DESKTOP-01).
- It records every top-level window found on the private desktop and on
  Default. Both inventories must be complete:
  - every `FALSE` from `EnumDesktopWindows` counts as unavailable;
  - a hidden sentinel window of the driver must appear on the private
    desktop;
  - Default must show at least one window.
- It then stops each process by exact PID, and counts what still runs: the
  same PID and creation time, not exited. A held handle keeps an exited
  process's creation time readable, so creation alone is no proof of life.
- Its claim is "every process and window alive at the sample". It holds only
  when the sample has the app, the ConPTY host (the copy's own
  `OpenConsole.exe`, or `conhost`) and the shell, and every desktop read in
  it resolved. A thread with no USER desktop is kept apart from an unreadable
  one, and an unreadable one leaves Q0 inconclusive. The growth of the job's
  `TotalProcesses` since the copy started is recorded beside the sample, so a
  descendant that joined and exited before it (cmd's `chcp`) is counted. It is
  outside the claim and does not fail Q0.
- An incomplete census also leaves Q0 inconclusive:
  - a descendant candidate the walk could not verify, unless it is gone, its
    PID now names another process, or it predates the ancestor it names
    (`unresolvedDescendantLinks` must be 0). Unresolved is not the only way
    the walk can miss a live process: when an intermediate's PID is reused by
    a newer child of the same ancestor, the intermediate's live child reads
    as older. The arm's job still holds such a grandchild, since it permits no
    breakaway (test-harnesses.md 2026-11-20 PROBE-JOB-BREAKAWAY-01), so the
    GUI census counts it and the CLI watch reads it or leaves the arm
    inconclusive. The walk is a cross-check;
  - a running child of a gone or reused candidate that is not in the arm's
    job (the walk does not pass through such a PID; it counts as unresolved);
  - more live processes in the job, by its active count right after the
    sample, than in-job rows (a GUI arm);
  - a member of the job's process list read at that same moment that is not
    a census row with the same PID and creation time, so an exit and a join
    cannot balance out (a GUI arm; the list is recorded as
    `jobMembersAtBoundary`, and a record without it is inconclusive). The
    list is read inside a bracket: the job's accounting before and after it
    must show the same total (nothing joined; the total only grows, and the
    job permits no breakaway) and the same active count, equal to the list's
    length (nothing left). An unstable bracket is retried up to 5 times and
    recorded (`boundaryBracket`); a stable one proves no member exited inside
    it, so every member must match by PID and creation time.
- Each walk also checks, on a handle held open, whether the owner of a
  window off the private desktop that is outside the census belongs to the
  arm's job (the CLI's watched job, or the GUI driver's own). A member's
  window counts as a job window there, so the arm cannot pass. An owner that
  cannot be opened is counted (`windowOwnersUnreadable`, beside
  `windowOwnersTotal`, the owners checked). An owner that exits
  between the walk and its open, taking its windows with it, is outside this
  check.
- Positive control: a child started without a desktop name reports the private
  desktop.
- Negative control: a thread moved to a second desktop with `SetThreadDesktop`
  starts a child that reports Default. While the child waits, Q0's own reader
  must name Default for both its startup desktop and its thread desktops.
  Desktop names compare case-insensitively, and a startup desktop the reader
  names neither way is recorded by its leaf.
- The enumeration classifier's own control runs in the bundled arm's driver:
  a fresh empty desktop, walked through the handle that created it, comes
  back with the empty walk's own signature (FALSE with no error), a walk
  through a handle that
  is not a desktop (an event of the driver's) comes back unavailable with a
  Win32 error, and the desktop holding the sentinel lists it. Anything else
  leaves Q0 inconclusive. A desktop handle without some access right is no
  such failure: on the Windows builds measured, `EnumDesktopWindows` walked
  every narrowed desktop handle tried, though Microsoft documents
  `DESKTOP_READOBJECTS` as required (test-harnesses.md 2026-11-20
  PROBE-ENUM-ACCESS-01).
- The CLI arm polls until its root has exited and its watched job holds no
  live process, then once more for what joined after the last snapshot.
- Q0 passes only when all three arms and every control pass. Its claim is
  "every process and window alive at a sample".

**D3**, run hosted only (`GITHUB_ACTIONS` and `RUNNER_ENVIRONMENT` checked).
On the runner's own Default desktop, each item has a control:

- **P1:** `SendInput` text reaches the script's own window, once that
  window's EDIT has the focus and it is in no menu loop. The foreground is
  unlocked by a zero-motion mouse input, not an Alt tap, which opens the menu
  loop and swallows the next key. Control: another window in front takes the
  input, and the probe's text is unchanged. Then the noctty arm: the
  measurement copy, foreground, is typed `echo <nonce>>"<file>"` and Enter,
  and the file must hold the nonce. Control: the same with a probe window in
  front, whose EDIT takes the line while no file appears. P1 passes only with
  both arms, and every stimulus counts only when `SendInput` inserted every
  event.
- **P2:** a #FF00FF window is read back one pixel at a time. Controls: the
  window covered, and the window minimised.
- **P3:** the fixture's shell prints a seed of known size: 20 lines of 64
  characters, 1320 bytes (`/K type <seed file>`).
  - In every arm, the backend is shown by the existing
    `initialized driver=WARP` line, the `renderer_windows` scope's one line
    (the WARP notice), and no logged backend switch.
  - On Default, a fresh render-trace snapshot (`NOCTTY_RENDER_TRACE_LIVE`,
    WM_APP + 8) shows a swap whose `last_swap_process_output_bytes` is at
    least the seed's bytes.
  - Control: the same run with the seed withheld stays below that.
  - Control: on a private desktop, a fresh `WM_PRINTCLIENT` readback of the
    pane (the test tools' `renderer.capture`) is the seeded frame, and a
    snapshot taken after it counts no swap.
  - Control: a private withheld-seed readback misses the seed text's pixel
    floor.
  - A failed readback, a missing snapshot, or a snapshot that lacks a counter
    is "inconclusive". The withheld readback counts only as the fixture's own
    background with a measured ink fraction below the floor.
- **P4:** `ITaskbarList3::HrInit`'s HRESULT on both desktops.
- **P5:** the toast setting and history count for the build's identities.
  The after-exit samples are taken only after a normal exit: `WM_CLOSE`
  posted, the process ended inside the wait, and exit code 0.

P4 reads the copy's own record. `NOCTTY_GUI_PROBE_TRACE=1`
(`src/os/gui_probe_trace.zig`) turns it on, and it needs `GHOSTTY_LOG=stderr`.

```powershell
pwsh -NoProfile -File test/windows/gui-hosted-probe.ps1 -Bin <measurement prefix>\bin `
    -MeasureRepo <repo> -Work <new dir> -Out <record.json> -Part Q0
```

`-Part` takes `Q0`, `Local` or `All`. `All` needs
`-TestToolsBin <test-tools prefix>\bin`; with `Local` it only feeds the gate's
control, which must refuse it. `-Work` must lie outside
`-MeasureRepo`, or in a folder git ignores there: copies staged in the
checkout would dirty it, and the driver's admission refuses a dirty one. The
probe checks this before it creates anything.

- `-Part Local` runs the gate's control, Q0, and the private-desktop facts of
  P4 and P5 on the measurement build. Given `-TestToolsBin`, it only feeds the
  gate's control, which must refuse it.
- `-Part All` refuses to start off a hosted runner, and needs
  `-TestToolsBin`.
- Locally, the run also:
  - keeps the real state's guard (`scripts/interactive-win11-state-guard.ps1`);
  - reads only the measurement identity's toast facts;
  - gives each noctty child a `TEMP` and `TMP` under its run directory;
  - deletes the copies it made under `-Work` once the record is written
    (`-KeepCopies` keeps them);
  - exits 3 after a tripped guard and 2 after a failed stage. The record
    names the guard (`guardTripped`) and its state (`guardTrippedState`,
    `tripped` or `unreadable`).
- On a hosted runner the probe is record-only and exits 0.
- A clipboard sequence sample of 0 cannot be read. Locally it stops the run,
  as a tripped guard does. On a hosted runner it is recorded
  (`guardUnreadable`) and gates no verdict: the guard protects the user's
  clipboard, and the runner's clipboard is not theirs.
- The record holds only values and HRESULTs. `Write-ProbeRecord` writes any
  other string, and any other type, as `rejected-value`, and leaves out an
  entry under any other key. No screen image, path, window title or command
  line enters it, nor any environment value but the hosted runner's image
  name and version, each kept only in its known shape (else `unknown`). The record is still written: it
  counts the replacements (`rejectedValues`) and lists where they were
  (`rejectedAt`, a left-out key as `#key<n>`, which no allowed key can
  match). A driver record with any replacement
  leaves the verdicts that read it inconclusive.
- Readbacks stay in `-Work`, and only their counts reach the record.

## hidden-win11-working-set.ps1

`PLAN.md` §3.5's working-set workloads: one portable copy of the
receipt-bound measurement build on a private desktop runs one fixed workload,
and the harness samples it through the handle it holds from `CreateProcess`.
It launches only the measurement generation of `-MeasureRepo`
(`Invoke-InteractiveWin11MeasureBuild`): `Assert-InteractiveWin11MeasureBuild`
admits it and the copied `noctty.exe` and `noctty.com` must match the
receipt's hashes, so a plain `zig-out` build is refused before anything
starts. Each run is a fresh copy, private desktop, job and `LOCALAPPDATA`, one
run at a time (a session-wide mutex refuses a second). The driver re-proves
its isolation before it starts anything (a job; its own desktop, neither
`Default` nor the input desktop; `LOCALAPPDATA`, `APPDATA`, `TEMP` and `TMP`
inside the run; the staged copy, its marker, no `noctty.ico`, the harness's
config and the receipt's bytes). Every process the harness creates directly
names the private desktop, and the native launches refuse any other: a child
only on the driver's own desktop, the driver never on the caller's, `Default`
or the input desktop. The driver's re-admission runs git through the measure
library, which names no desktop; per `CreateProcess` such a child inherits its
parent's desktop, the driver's private one (read, not measured). The staged
config must be byte for byte the harness's own for the run
(`New-WorkingSetConfigText`), so an `initial-command` or a second `command`
cannot change the first pane's shell, and only its settings take effect. The
copy is launched with exactly the expected argument list (the launch
helper's arguments, then the harness's, in order and nothing else), among
them `--config-default-files=false` and `--config-file=<copy>\config.ghostty`:
the final command line before the launch, and the copy's own command line by
PID after it, must each split into exactly that list. noctty still reads its
default config files, then discards their settings because default files are
off (`Config.loadCliArgs`), so the settings in effect are the command line's
and the `--config-file` file's; a staged copy holding a legacy
`ghostty\config` or `winghostty\config.ghostty` is refused as well. The run's
path appears in the config only as
`working-directory`: F5 types `.\flood.cmd`, relative to the pane's working
directory, so a `%USERNAME%`, `^` or `&` in the path never reaches cmd's
parser. `NOCTTY_CONPTY` must be unset (both
halves refuse it), the copy's `conpty.dll` and `OpenConsole.exe` must match
the build's, and the record keeps the transport the copy's own log names
(`using bundled ConPTY: <copy>\conpty.dll`); a run on any other transport
fails. The copy starts through
`Get-InteractiveWin11LaunchArguments` (its own class) after its build mode is
checked through `+version`, with its config's
`command = direct:<System32>\cmd.exe /D`, the clipboard denied, no
`noctty.ico`, `SEM_NOGPFAULTERRORBOX` and a job that ends a process on an
unhandled exception, the driver and the copy at normal priority. The grid is
read from the base pane's pseudoconsole before `start` and must be 140 x 43:
on the measurement machine (144 DPI) the config's `window-width = 140` and
`window-height = 45` give 43 rows, measured on the 0a build and on this
harness's, so the harness pins that grid (`$script:GridRows`), not the
configured 45. The flagship configured-size leaf
(`interactive-win11-configured-size.ps1`) likewise accepts a configured size
with a tolerance (its 140 x 45 needs at least 120 x 35).

Each sample holds `private_bytes` (`PrivateUsage`, what Windows calls the
process's commit charge), `working_set`, `peak_working_set`,
`private_plus_shared_commit` (`PrivateUsage + SharedCommitUsage`), the pane
count and whether it is the base pane alone, and the handle, GDI and USER
counts (null when their query failed). A stage settles once the last 10
samples, 500 ms apart, hold private bytes within 0.5% and working set within
1% of their mean (range over mean); its value is its last sample. A stage
that has not settled after 90 s, or that is not at the base pane alone, fails
the run. The scrollback workloads' `block-<n>` entries are the exception, by
design: one immediate sample each, right after its block, not settled and
exempt from both checks (the comparison uses the settled `after`). The workloads, on the 140 x 43 grid, in blocks of 25,000 lines; a block
counts once the batch file acknowledged it and the copy's window title shows
`ws-block-<n>`, which the batch file sets after the block, so the pane parsed
through its end:

- `fixed`: one block, then 20 cycles of a new tab and its close; `after` 7 s
  later (undo-timeout prunes closed panes after 5 s) and once the copy is back
  to its base pane alone.
- `scrollback-default`: 4 blocks at the default `scrollback-limit`
  (10,000,000 bytes), about ten times what it retains at this width.
- `scrollback-max`: 1.25 times what `-ScrollbackMaxBytes` holds at 1,120
  bytes a row (about twice the limit, measured), with that limit. noctty has
  no maximum; the default, 1 GiB, is the baseline's large scrollback point.
  Settings' up-down stops at 2,147,483,647, which caps the parameter; that
  value is not measured (a 2 GiB working set adds nothing the 1 GiB point's
  growth does not show).
- `uia-walk`: `scrollback-default`'s output, then a UIA client reads the
  pane's whole `DocumentRange` and walks it line by line to its end, the pane
  found from the copy's own window handle. It reads only what UIA exposes at
  the bottom of the scrollback, 329 lines at 140 columns (measured), not a
  scrolling walk of the whole scrollback: `accessibleHistoryRows` in
  `src/apprt/win32_uia/text.zig` exposes min(40,000 cells / columns, 500)
  history rows plus the viewport (285 + 43 rows here), and the window slides
  only with a scrolled viewport (`snapshotDocumentWindow`), which this
  workload never scrolls. The walk counts only when the document holds the
  last block's last line and the walk counted the whole document: the history
  rows, the viewport and the one line more a walk counts, 329 lines at
  140 x 43 (`Get-ExpectedUiaLines`); a 285-line document, the history rows
  alone, fails. Its `after`
  stage is sampled with the UIA client still connected: about 20 more handles
  than `start` in every Phase 0a run (595-599 against 575-579).
- `session-capture`: `scrollback-default`'s output with
  `window-save-state = always` and `window-save-state-scrollback = 10000`,
  then 10 checkpoints, each a new tab and its close; a checkpoint counts only
  when the copy's own `session-state.json` then holds a new snapshot of the
  base pane with the fixture's lines, its `captured_at_unix_ms` later than
  both the close (timed right before the close key) and the last snapshot
  counted, so a display-change or deferred save from before the close does
  not count, and only a snapshot of exactly the lines its budget gives
  (`Get-ExpectedSessionLines`, 3,717 at 140 columns), so a halved slice from
  the formatter's retry (1,858 lines) does not count either; the record keeps
  each checkpoint's times and line counts. The
  512 KiB snapshot budget pre-limits a capture to (budget - 96 bytes of
  snapshot overhead) / (columns + 1) lines, 3,717 at 140 columns (counted), so the 10,000-line cap is not
  reached at this width. This is the only workload that saves session state,
  an exception to AGENTS.md's `--window-save-state=never`: the file stays in
  the portable copy, and the real `session-state.json` is guarded.
- `tab-churn`: 50 cycles of a new tab and its close.

```powershell
pwsh -NoProfile -File test/windows/hidden-win11-working-set.ps1 `
    -MeasureRepo <checkout with a measurement build> -Run <new dir> -Workload fixed
```

`-Run` is a new directory outside `-MeasureRepo`, or one git ignores there: a
run directory inside the checkout would leave untracked files that the
measurement build's provenance check refuses, so the harness refuses it
before it creates anything.

A later phase compares its working set with Phase 0a's by running the 0a
measurement build and the new one interleaved, under the same harness
version, one copy at a time on a quiet machine, and comparing each workload's
median `after`; the stored 0a numbers are the reference level, not the
comparison. Only completed runs count (the outer half checks each
`workingset.json` with `Get-WorkingSetRecordProblems` before it says
"complete") with the same `WorkloadSha256` (the workload, its scrollback limit
and planned blocks, the constants, the output block, the flood batch file and
the config) and grid, and both arms on the same transport and bundle: the
bundled ConPTY, with the same `conpty.dll` and `OpenConsole.exe` digests in
their records. One copy at a time, 9 Phase 0a copies' settled `start`
levels had IQRs of 0.1-1.6 MiB and their `after` levels up to 2.7 MiB (7.5 MiB
at the 1 GiB limit), with one unexplained low run, while copies run together
differed by tens of MiB (test-harnesses.md, the 2026-11-20 WORKING-SET-01
entry and trap 6 of the 2026-11-18 SOAK-01 entry). The real startup ledger,
the product jump list and the clipboard sequence number go through the shared
state guard (`scripts/interactive-win11-state-guard.ps1`), the PowerShell
history through `scripts/windows-harness-history.ps1`, and the real
`session-state.json` is compared by metadata. Contracts.98-WorkingSet pins the
harness, its workload and its run-time checks.

## bench-frame-pacing.ps1

`bench-windows.ps1 -Metric frame-pacing` runs this harness: `frame_time_p95_ms`
under the per-copy rules (AGENTS.md "Running noctty"). Each run is a fresh
portable copy of `-MeasureRepo`'s receipt-bound measurement build
(`noctty.portable` beside it, no `noctty.ico`, its own `LOCALAPPDATA`,
`APPDATA`, `TEMP` and `TMP`), admitted as `hidden-win11-working-set.ps1`
admits it. The admission, the no-follow receipt read, the copy check, the run
placement, the stray-config check and the argv comparison are that harness's
functions, copied byte for byte; Contracts.99-FramePacing fails if either copy
changes alone, and holds the bench's statistics and payload generator and the
native members #739 hardened the same way. The copy's shell is its config's
`command = direct:<System32>\cmd.exe /D`. Nothing on its command line sets
one: the final command line and the copy's own, read back by PID, must each
split into exactly the expected list, `--config-default-files=false` and
`--config-file=<copy>\config.ghostty` among it. The clipboard is denied, and
no PowerShell runs under the copy (checked at the end of each run). Its
environment adds only `GHOSTTY_LOG`, `NOCTTY_RENDER_TRACE_FILE`,
`NOCTTY_RENDER_TRACE_LIVE` and `NOCTTY_BENCH_END_MARKER`; an inherited
`NOCTTY_` or `GHOSTTY_` variable is refused.

The workload is the bench's `stream` payload (4 MiB of printable ASCII from
its own generator, seed 121) and end marker, written by cmd's own `type`. F5
types `type stream.bin & echo.>done.flag`. The driver waits for the echo to go
quiet, then arms the render trace for the first swap that presents the end
marker (`WM_APP + 9` with 0), and F6 sends the carriage return. Nothing is sent
to the pane inside the window, because noctty writes a trace snapshot on the
presenting thread: the driver polls `done.flag` as a file, waits 1 s, then
requests one snapshot at a time until one shows the end marker's swap. A
snapshot that still shows the target armed landed inside the window, is
counted (`SnapshotsInWindow`), and makes the run inconclusive. The samples
are the trace's intervals between consecutive successful swaps, from the arm
through that swap, kept in memory by the trace, at most 2,048 a run. `frame_time_p95_ms` is their nearest-rank p95,
pooled over the completed runs, as the bench aggregates its own. cmd's `type`
delivers the payload at about 2.4 MB/s, a tenth of the bench's PowerShell
producer (26 MB/s in the 2026-08-27 table in
`docs/windows-benchmark-methodology.md`), so a run's window is about 1.8 s
with about 420 intervals, and its numbers are not comparable with that table.
`copy /b stream.bin con` is fast but loses the end marker (test-harnesses.md,
FRAME-PACING-01).

Two modes:

- The dry run (the default) runs everything on a fresh private desktop and
  refuses the visible part: the driver evaluates the visible run's
  preconditions on its own desktop, records why they fail, and never takes the
  foreground. Its intervals check the pipeline and are not a measurement, since
  nothing composes a private desktop. The summary gives their p95 as
  `dry_run_p95_ms`, never as `frame_time_p95_ms`.
- `-Visible` is the measurement. Run it only while the machine's user is
  away. The copy runs on `Default`, which must be the caller's desktop and the
  input desktop, composed by DWM, in a local session, with the shell accepting
  notifications (no full-screen app or presentation mode), the display on, no
  screen saver running, and Windows' foreground lock
  (`SPI_GETFOREGROUNDLOCKTIMEOUT`) longer than the series needs. There must be
  no keyboard or mouse input for 300 s before the series (a pinned constant).
  The lock counts from the user's last input, so it must outlast the idle
  time seen at admission (at least 300 s) plus every run's longest duration
  (`Get-FramePacingLockNeedMs`: 2,100,000 ms a run, the driver's 30 min
  deadline plus 5 min for staging and the guards). With the default
  200,000 ms the lock has expired before the first copy starts, so
  `-Visible` is refused. The admission prints both values, and each run
  records them (`ForegroundLockTimeoutMs`, `ForegroundLockNeededMs`). The lock
  is read again before each run's driver starts and right before each copy's
  launch, after `+version`'s wait (`ForegroundLockTimeoutAtLaunchMs`), so a
  setting changed during the series stops it.
  "Away" means only that: a gamepad, or a video watched without input, is not
  seen. The series holds the display and the system on.
- Real input is detected by the injected flag, not inferred from ticks.
  `GetLastInputInfo` cannot tell the harness's own unlock from the user's
  input. From admission to the series' end the outer half holds low-level
  keyboard and mouse hooks (`WH_KEYBOARD_LL`, `WH_MOUSE_LL`) on a thread with
  its own message loop. Any event without `LLKHF_INJECTED` or `LLMHF_INJECTED`
  is real input and sets the series' event, which every driver opens. The
  callbacks read two words of each event, its flags and its extra info, never
  a key code or a position; they keep counts, set an event and pass the event
  on. Hooks that do not install refuse `-Visible`; there is no fallback to the
  tick alone. Contracts.99-FramePacing pins the callbacks, the watch's start,
  stop and wait, and both workers by the SHA-256 of their text.
- Each hook's proof of life is the harness's own input of its kind. Windows
  removes a low-level hook whose callback runs past `LowLevelHooksTimeout`
  without notice, and a removed hook would leave the real-input event clear
  for good. The callbacks are trivial, so a timeout needs a long pause of the
  outer half. The harness's own injected input carries a random marker drawn
  for the series in its extra info, and only an event carrying it counts as
  proof: another program's injected event (a jiggler, a script, a KVM) is
  counted and proves nothing. The mouse hook's proof is the unlock: the worker
  waits for the marked mouse event before it takes the foreground. The
  keyboard hook's proof is the keyboard probe below: the probe's worker waits
  for the marked key. The outer half also checks that each kind's marked count
  moved after each run. Any miss refuses the run, and the series stops. The
  keyboard proof comes after the foreground step, so until then a
  keyboard-only return is caught by the tick, apart from the millisecond race
  at the unlock. Between one run's proofs and the next nothing is injected, so
  the later gates rely on them.
- What the injected flag cannot see (read from Microsoft's documentation,
  not measured): keystrokes into an elevated window, which a non-elevated
  low-level hook does not get, and input that a software KVM or a
  remote-input tool delivers through `SendInput`, which carries the injected
  flag. Both still move the session's last-input tick, which the gate checks
  second, except within a few milliseconds of the harness's own injected
  input (the unlock and the keyboard probe). For that input the outer half
  never wakes: the copy ends at the driver's next tick check. Every wait the
  driver makes reads the gate at each 100 ms: the waits on the copy's
  window, its quiet and its quit, on `+version` and the probes, the quiet
  machine wait, the load readings (sampled around the polls) and a
  render-trace snapshot's wait for its file. What does not poll, with its
  worst case: a render-trace request's window-message call (each snapshot and
  the arm), up to 5 s (`ResponseBoundMs`) if the copy stops answering, after
  which its file wait, polled, can take up to 10 s more; the display-power
  reading, at once in practice and at most 2 s; and the bounded foreground
  and keyboard-probe workers, milliseconds in practice and at most 5 s each,
  which read the tick right before each action. These are per step, and two
  can run back to back: the keyboard-probe worker (up to 2 s after its
  input) and then a trace request's message call (5 s) make about 7 s. So
  input the hooks cannot see reaches the copy for at most about 7 s, and only
  if the copy stops answering; normally within 100 ms. Before the foreground
  step two more calls do not poll: the WMI read of the copy's command line
  right after its launch (`Get-CimInstance`, with no bound of its own) and
  the foreground's `WM_NULL` check before its worker (up to 5 s). Under the
  foreground lock the copy is not in front then, so they matter only on the
  startup-activation path below. Input the gate finds
  after the window, or right before the quit, ends the copy at once. After
  each run the outer half reads the tick against the last tick the harness's
  own marked input left (the probe's, else the unlock's, else the series'):
  a moved tick makes the run inconclusive like hook-seen input, and at the
  series' end the same reading against the series' baseline voids the
  series (below).
- The input gate (`Test-FramePacingInputGate`) reads that event first. The
  session's last-input tick is the second line: it must be the series' tick
  until the unlock and the harness's own latest tick after it. The gate runs
  right before each launch on `Default` (the visible driver's included), the
  unlock, right after the copy is in front, the keyboard probe, each workload
  key (F5 and F6) and the measured window, and at each 100 ms poll of every
  wait the driver makes, inside the window and before it. On real input the
  run stops at once: nothing further starts, takes the foreground or sends
  input, the catch ends the copy, and input inside the window makes the run
  inconclusive, never a timeout's failure. The outer half waits on the
  hooks' real-input latch and the driver together (the latch first, so input
  that arrives as the driver ends still counts) and closes the run's job, and
  with it the copy, the moment it observes the latch, inside the same native
  call and with no grace: immediately on observation, plus OS scheduling
  latency. That holds even while the driver is busy in a step that does not
  poll (the copy's launch, a 2 s load reading). Each run records the delay
  from that observation until job accounting shows no active process and
  `StopOwnedJob` has closed the job's handle (its return; `LatchToKillMs` in
  `guards.json` and `latch_to_kill_ms` in `pacing.json`, from
  QueryPerformanceCounter). The driver's own process handle can signal a
  millisecond or so later; its threads have already ended.
  This bound and the per-poll gate apply to input the hooks see; input they
  cannot see is bounded by the driver's tick checks (above). Real input the
  hooks see at any point in a series makes the series inconclusive and
  publishes no metric, whatever any driver's own exit says. The machine must be
  under 30% busy (the driver waits up to `-QuietWaitSeconds` and launches
  nothing when it never was) and again right before the window, with no
  screen saver then either; each reading is acted on at once.
- The foreground: a zero-motion mouse input unlocks it, never an Alt tap,
  then one `SetForegroundWindow`, which Windows allows the process that sent
  the last input. There is no `AttachThreadInput` fallback, no
  `BringWindowToTop` and no keyboard-state reset anywhere: attaching to the
  user's foreground thread resets its key state and could clear a modifier a
  returning user holds. The native worker checks the event right before its
  input, refuses the unlock unless a valid tick moved and the mouse hook saw
  it, reads the tick again and checks the event right before the foreground
  call, then lets the copy's queue take the activation (a bounded `WM_NULL`
  round trip and up to 500 ms of polling, reading the event each time) before
  it reports "refused". It works on its own copies of the event handles and
  runs joined within 5 s; a timeout cancels any step it has not taken. A run
  whose foreground, pane focus, display power or session input changed is
  inconclusive, never a sample.
- The keyboard probe: once the copy is in front and the gate has run again,
  one `SendInput` of VK_NONAME (0xFC) down and up, marked, behind the same
  stop check; the copy must still be in front, and the keyboard hook must see
  the marked key. It reaches only the copy's own pseudoconsole. What noctty
  writes for it, from the test in `src/apprt/win32/input.zig` that runs it
  through noctty's key message builder and encoder:

  | Win32 input mode (9001) | Key down writes | Key up writes |
  | --- | --- | --- |
  | Off | nothing | nothing |
  | On | `ESC[252;0;0;1;0;1_` | `ESC[252;0;0;0;0;1_` |

  Each record is a `KEY_EVENT_RECORD` with virtual key 252, scan code 0 and
  no character. That cmd ignores it is measured in every dry run: the driver
  posts the same down and up to the copy's pane before F5, reads cmd's console
  through the pseudoconsole before and after, from its top-left cell through
  the cursor so a prompt or command that wraps is read whole, and requires it
  unchanged (`DryProbePromptUnchanged`), then requires it to be exactly the
  console before plus F5's command (`DryProbeCommandIntact`).
- A check cannot be closed against the action right after it: input can land
  in the sub-millisecond gap between them. What each guarded action can do to
  a user whose input lands in that gap:

  | Action | Checked right before | Worst case for a user who returns in the gap |
  | --- | --- | --- |
  | A launch on `Default` (the driver, `+version`, the copy, the grid probe) | the event, then the tick | A process starts. The copy's window may show, but its own activation is subject to the foreground lock (below); the copy is closed as soon as the outer half observes the input. |
  | The unlock (`SendInput`, `MOUSEEVENTF_MOVE`, dx = dy = 0) | the event, on the worker | None visible: no motion, no button, no key. The session's last-input tick moves. |
  | `SetForegroundWindow` on the copy | the timeout's cancellation, the tick, then the event, on the worker | The copy comes in front once, or Windows refuses it because the user's input now came last. Keys the user types go to the copy's cmd until the outer half closes the copy on observing the input, or the gate's next poll stops the run, within 100 ms, whichever comes first. |
  | The keyboard probe (`SendInput`, VK_NONAME down and up) | the copy in front, the tick, then the event, on the worker | If the user clicked elsewhere inside the gap, their app gets an unassigned key down and up, which has no binding and no character. |
  | F5, F6 and the dry run's VK_NONAME (`WM_KEYDOWN`/`WM_KEYUP` posted) | the event, then the tick | The key reaches the copy's own window only, never the user's application. |

- What the foreground lock covers, and what it does not. noctty's own first
  show (`Host.present`: `ShowWindow`, then `SetForegroundWindow`) is not the
  harness's call, and only a default-terminal handoff reads a launch's show
  state: the harness cannot stop that call. It relies on the lock to keep the
  call from taking the foreground, and closes the copy as soon as it observes
  any real input. Under Microsoft's documented rules a background process that is
  not in front, was not started by the foreground process and did not receive
  the last input cannot take the foreground until the lock's timeout has
  passed since the last input. That leaves three paths uncovered: no window
  holds the foreground at all (each run closes its own copy, and Windows may
  activate nothing after it), the returning user's first input lands on the
  copy's newly shown window, and a foreground right passed down the launch
  chain (outer pwsh, driver, copy), which the documentation does not address.
  The first path includes this interleaving: the user's foreground window
  disappears while the copy is starting (the user closes it, or it closes
  itself), and the user's real input arrives during that startup. With no
  foreground window when the copy first shows, its activation can take the
  foreground despite the lock. The harness accepts this as a residual, with no
  mechanism of its own: the hooks' latch is set by that input and the outer
  half closes the copy immediately on observing it, which bounds how long the
  copy holds the foreground. All of this is inferred from the documentation,
  not measured with a returning user. Each visible run records whether a window held the
  foreground right before the copy's launch (`ForegroundBeforeLaunch`) and
  whether the copy held it right before the harness's unlock
  (`ForegroundBeforeUnlock`). A copy in front after no window was is recorded
  (`ForegroundTakenFromNone`) and allowed, since that path is harmless while
  the user is away; a copy that took the foreground from another window
  contradicts the lock claim, so the run is inconclusive and the series
  stops. That check tests the lock only while the lock is in force: before
  each launch the harness requires the lock to outlast the idle time since
  the user's last input plus the remaining runs' budget, and a visible run's
  staging and guard setup that ran past their 300,000 ms bound launches no
  driver; either way the series stops inconclusive.

```powershell
pwsh -NoProfile -File test/windows/bench-windows.ps1 -Metric frame-pacing `
    -MeasureRepo <checkout with a measurement build> -RunRoot <new dir> [-Runs 5] [-Visible]
```

`-RunRoot` is a new directory outside `-MeasureRepo`, or one git ignores
there. The series stops at the first run that does not complete. The exit
code, by precedence (`Get-FramePacingExitCode`): 3 when a guard tripped, else
1 when a run failed or the runs differ in build or workload, else 2 when a run
was inconclusive or the runs differ in environment, else 0. A series that both
trips a guard and differs in build exits 3. `<RunRoot>\pacing.json` holds each
run's status and statistics, each comparability group's (`Groups`), the pooled
p95 and, in a visible series, how many real and injected input events the
hooks saw (`RealInputsSeen`, `InjectedInputsSeen`, the latter every injected
event, the harness's own marked ones and any other program's). Each `run-<n>` holds
`run.json` (the build,
config, receipt and ConPTY digests, the transport and renderer the copy's log
names, the grid, the window's DPI and monitor mode, the busy share and timer
resolution before and after, every interval and the visible part's facts), the
copy's log, the driver's log, the copy's last trace snapshot and
`guards.json`. The summary pools only comparable runs: the same
`WorkloadSha256`, app, renderer, transport and ConPTY digests (a difference
fails the series, exit 1), and the same display mode (the window's monitor's
width, height and refresh, read at the start of each run and again after its
window, where a change makes the run inconclusive), DPI and grid (a difference
pools none and exits 2). Each group of runs alike in all nine of those fields
is reported on its own in `Groups`, never combined across any of them.
`frame_time_p95_ms` and its median are published only for a visible series
with no real input the hooks saw (`RealInputsSeen` 0) and a session tick
still at the series' baseline (`TickMovedFromBaseline` false), whose every
run completed and whose runs are comparable; otherwise both are null, input
makes the series inconclusive (exit 2 unless a guard or a failure ranks
higher), and the console says no measurement was published. A series that
input voided writes no timing statistic at all: each group's `p95_ms` and
`median_ms` and each run's `p95_ms` in `pacing.json` are null too, and its
`Inconclusive` names what voided it (the hooks' count, a tick that moved or
could not be read, or a watch that did not stop). Each run's own `run.json`
keeps its evidence for debugging. The series ends
in this order: every run has ended and its job, with its copy, is closed;
the watch stops, which unhooks; the final real-input count and the tick are
read; then the summary. Input after the unhook reaches no copy. A visible
run is never complete without the keyboard probe's "ok": a run whose
foreground was taken without one stops the series as inconclusive, never
failed, and its line names the cause the driver recorded (a refusal, or
input the hooks did not see). Only a hook that missed the harness's own
marked input fails the run, as Windows may have removed it: a count that did
not move, or the driver's refusal when a hook did not see the unlock or the
probe. Such a run stays failed whatever input stop follows, and the tick the
unlock or the probe moved is kept as the harness's own even when the hook
missed it, so it is never read as a user's input. A
`run.json` the job's close cut short reads as no record: a run stopped for
real input is then inconclusive, any other run failed, and the series still
writes `pacing.json`. A staging failure is a
failed run before any launch, and the summary still records the runs before
it. What runs is the run's own copy: its path is checked before any launch
and its image read back by PID, and the driver runs in the run's own job,
checked before it resumes and again by the outer half. The shared state guard
owns the measurement-identity jump list by its timestamps: it deletes the file
only when it did not exist before the run and both its creation and last-write
times fall inside the run. It keeps one that existed before, and keeps one
whose times fall outside the run (NTFS tunnelling can keep an old creation
time) and reports that as a failure. Another measurement workload's jump list
written during a run would pass that test and be deleted, so run one
measurement workload at a time; the frame-pacing mutex covers only this
harness. Each run keeps the shared state
guard, the PowerShell history guard and the real `session-state.json`'s
metadata, and logs the clipboard sequence number before and after.

## Style

- Define reusable helpers as `function Verb-Noun { ... }` with a `param(...)`
  block and typed, PascalCase parameters where practical.
- Resolve `$repoRoot` once, then dot-source shared code with
  `. (Join-Path $repoRoot 'scripts\name.ps1')`.
- Aim for roughly 120 columns. Wrap multi-parameter invocations with splatting
  or aligned continuations; keep indivisible diagnostic strings and pinned
  regular expressions intact.

## test_dll_init.c

Packaged ghostty-vt.dll smoke. The portable ZIP carries a noctty placeholder
under that name, not libghostty-vt (see
[Library consumers](../../PACKAGING.md#library-consumers)), and this checks the file a package carries is the placeholder:
`LoadLibraryExW` fails with `ERROR_DLL_INIT_FAILED` (1114), the export table
is empty (read from the file, so nothing in it runs), and the version
resource's FileDescription is the one passed in. The portable package CLI
smoke (`package-portable-cli.ps1`) compiles and runs it against the packaged
x64 DLL, and the native ARM64 job (`.github/workflows/windows-arm64.yml`, its
packaged smoke step) against the packaged arm64 DLL, both passing
`$GhosttyVtStubDescription` from `scripts/ghostty-vt-stub.ps1`.

### Build

From the repository root, build noctty (which builds the placeholder into
`zig-out\bin\ghostty-vt-stub\`) and compile the test:

```powershell
zig build -Demit-exe=true
zig cc test/windows/test_dll_init.c -lshell32 -lversion -o test_dll_init.exe
```

### Run

Pass the absolute path of the built or packaged DLL and the expected
FileDescription:

```powershell
. .\scripts\ghostty-vt-stub.ps1
.\test_dll_init.exe (Resolve-Path .\zig-out\bin\ghostty-vt-stub\ghostty-vt.dll).Path $GhosttyVtStubDescription
```

Expected output:

```text
ghostty-vt.dll placeholder smoke: 3/3 checks passed
```

A DLL that loads (libghostty-vt from `zig build -Demit-lib-vt=true` does),
fails to load for any other reason, has an export table or carries another
FileDescription fails the smoke.

## Published portable direct updates

`direct-update-acceptance.ps1` exercises the published source release's own
updater against the candidate's GitHub tag API feed. It downloads both portable
ZIPs into separate new directories, verifies their published SHA-256 values
before extraction, posts the configured check key and Install notification,
restarts the copy, and waits for confirmation and helper finalization. It
records versions, folder inventories, a sanitized state timeline, and the final
stub's signature, publisher pin, description, empty export/import directories,
load failure (1114), and equality with the verified candidate ZIP.

Invoke from noninteractive automation, or from a caller whose PSReadLine history
was already set to a run-local path or `SaveNothing` before its first read.
Typing a wrapper command in an ordinary interactive host can itself enter the
real history before this script starts; the metadata guard cannot prevent that.

```powershell
./test/windows/direct-update-acceptance.ps1 `
    -Run H:\scratch\direct-update-136-137-NEW `
    -FromVersion 1.3.136 -TargetVersion 1.3.137 -Architecture x64
```

The run directory must not exist. Every harness launch names a private desktop;
the driver inherits an explicit whitelist of standard Windows runtime/profile
variables with separate LOCALAPPDATA, APPDATA and temporary directories, excluding
workflow credentials and other caller-defined variables. Standard Windows profile
identity is retained; this is application-state isolation, not a separate OS account.
The controller must observe Default. Downloads check both system and run-volume
space (resolving the run's existing ancestor through junctions), use GitHub CLI
requests bounded by `TimeoutSeconds`, and verify the publisher of both noctty.exe
and its console shim before either runs. Receipts publish by a sibling-file rename
after serialization and preserve zero/one/many array shapes. Inventories include
hidden files and files within hidden directories. Trailing run-path separators
are removed while drive roots are preserved.
The parent samples owned windows on both Default and the named private desktop,
and checks clipboard sequence and PSReadLine history metadata. A sample cannot
prove the placement of a window that existed entirely between samples.
No clipboard contents are read. Local guards read the real startup-attempts.json
to compute its hash and inspect its mtime; they do not write it. Keep failed attempts.

Run 1.3.125 only on a disposable GitHub-hosted runner: that historical binary
writes the product AUMID registration and Shell jump list even in portable mode.
Redirecting APPDATA does not isolate those writes. OS and PowerShell process
architectures must both match `-Architecture`; x64 emulation proves no ARM64 run.
The historical self-signed publisher is verified cryptographically against the
updater pin through the existing release verifier, without a trust-store import.

For the 1.3.125 to 1.3.137 stub case, `-HostedMesa` explicitly opts a disposable
hosted runner into Mesa 26.3.0 llvmpipe from `mmozeiko/build-mesa`. It is off by
default and refused for other source/target cases. Its HTTP fetch has a separate
`TimeoutSeconds` cancellation budget covering the response body. Both native archive hashes
are pinned and checked before extraction. Only `opengl32.dll` is added beside
the 1.3.125 executable; the receipt proves one extra file, its PE architecture,
the loaded module's backing file, and preservation through the update. The
candidate ZIP remains unchanged. This version uses its automatic check and a
posted pair to the source-defined painted Install rectangle on the host window.
No terminal mouse message or real input is used. This proves the updater path;
it does not establish composed rendering or physical mouse behavior.

For the v1.4.100 boundary, `-Expected Rejected` checks that a source on 1.3.136
stays on its original executable and runs, reports the incomplete portable ZIP,
and offers Open Release. `-Expected Removed`, from the previous stub-bearing
1.3.x, checks that a successful update removes the stub. Opening the release
page and checking its manual instructions is a separate browser check. Neither
future boundary is established by the 1.3.137 acceptance run. Rejected also checks
every original file hash and reads its journal strictly: absence and a readable
clear transaction pass; unreadable, locked or malformed state fails. The reader
decodes the bytes as strict UTF-8, then removes at most one leading UTF-8 BOM.
It uses `System.Text.Json` without comments or trailing commas, rejects duplicate
or case-colliding keys recursively, and requires all 17 fields written by
1.3.136 for a strict Rejected verdict. Empty objects and unquoted keys fail.

Updater diagnostics recognize `update_github_releases` and `update_portable_apply`.
Receipts retain the level and scope for each matching line and omit its message,
so paths, URLs and arbitrary release text never enter the exported diagnostic.
The published versions emit warnings only for updater errors/cleanup trouble;
the portable apply helper has debug-only directory-sync diagnostics. A clean
release-mode update can therefore leave this field empty. The state timeline,
file hashes and exit codes remain the acceptance evidence.

Every launch pins a direct absolute System32 cmd with `/D` and denies clipboard
reads and writes. Local runs additionally use the local harness library's real
startup-state fingerprint and the product AUMID's own jump-list metadata guard.
Other applications' jump-list changes are ignored. These detect mutations;
they do not establish the absence of reads or identical writes. The receipt
reports that limit instead of asserting no real-directory access. Private-window
samples are retained and must contain the driver sentinel. A hidden STATIC helper
on Default provides a positive control of the job window oracle before noctty
starts. Hosted runs require a sequence-number positive control in a fresh
unnamed window station, checked to differ from WinSta0 before every clipboard
operation. After noctty exits and its normal before/after counter comparison is
complete, a second hosted-only helper writes fixed fixture text to WinSta0 and
requires the parent's actual reader to observe the change. Both the script and
native helper require a disposable GitHub-hosted runner; the helper also checks
WinSta0 and its private desktop identity before every clipboard operation. This
intentional control is recorded separately from the noctty run's counter pair.
Local runs perform no clipboard write, and no clipboard contents are ever read.

Successful updates must sample `swapped` followed by `confirmed`; a cleared,
abandoned transaction fails. Rejected mode compares SHA-256 for every original
source file and permits extra files only for explicitly named generated runtime
artifacts; it also requires no staged transaction. Removed mode validates the
source stub before applying and its absence afterwards. Those modes still need
the actual v1.4.100 candidate; opening the release page stays a separate check.
Each input receipt records the checkout commit and harness/helper hashes. Keep
the scratch hosted branch for future native ARM64 runs, with its `windows-2025`
and `windows-11-arm` runner labels. Add `-HostedMesa` only for the pinned
1.3.125 to 1.3.137 case.

Run `direct-update-contract.ps1` for static refusal controls and the harness's
actual verdict functions against synthetic files and receipts. Parse-valid
here-string, disabled-guard, forged-stub, clipboard, confirmation,
executable-identity and sidecar mutants must fail; the flagship gate includes it.
The hosted definition, historical/Mesa/desktop guards and Default positive are
pinned by executable AST shape. Clipboard-helper admission masks C# strings and
comments, refuses conditional compilation and requires exact native call counts;
extra unguarded calls and inert copies fail. The parent's positive counters must
also equal the helper's own before/after pair.
Public artifacts should contain only the named JSON receipts, never the raw child logs,
copied profiles or binaries. The hosted workflow used to gather W10 evidence is
scratch-only and is not part of this change.
