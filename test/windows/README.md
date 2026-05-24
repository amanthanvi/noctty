# Windows Tests

Manual and interactive harnesses for Windows-specific functionality.

Each interactive Win11 harness uses its own repo-local sandbox under
`.sandbox\win11\<worktree-id>\<sandbox-name>`, so `-ResetState` resets
only that harness's logs/temp state instead of tearing down sibling
validators.

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
when tracked inputs are newer than `zig-out\bin\winghostty.exe`, so child
harnesses reuse one fresh binary instead of rebuilding in parallel.

## interactive-win11-smoke.ps1

Interactive Win11 startup smoke validation. It launches `winghostty`
inside the repo-local Win11 sandbox and waits for shell startup to be
observed in stderr.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-smoke.ps1 -ResetState -TimeoutSeconds 10
```

## interactive-win11-command-finish.ps1

Interactive Win11 validation for command-finished notifications. It launches
`winghostty` inside the repo-local Win11 sandbox, emits raw OSC `133;C`,
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
files under `src\` are newer than `zig-out\bin\winghostty.exe`. Pass
`-Rebuild` to force a full rebuild anyway.

## vt-probe-win32-conformance.ps1

Win32 VT protocol conformance metadata validation. It runs `+vt-probe` and
asserts that each advertised protocol reports a separate Win32-runtime
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
referenced by `+vt-probe`: command finish / notification, taskbar progress,
and synchronized-output repaint performance.

## interactive-win11-progress.ps1

Interactive Win11 validation for native progress state changes. It
launches `winghostty` inside the repo-local Win11 sandbox, emits raw
OSC `9;4` state transitions for `set`, `pause`, `error`,
`indeterminate`, and `remove`, captures the `winghostty` window via
screenshots for each state, and fails if:

- the runtime logs `taskbar progress init failed`,
  `taskbar progress sync failed`, or a crash
- the runtime never logs one of the expected taskbar progress sync
  states (`set`, `pause`, `error`, `indeterminate`, `remove`)

The script reports whether captured `set`/`remove` and `pause`/`error`
window images differ, and does the same for bottom-of-screen strips.
These image comparisons are diagnostic only: hosted desktop environments
do not always expose the rendered shell surface or Explorer taskbar to
screen capture, and bottom-strip captures can include unrelated desktop
content.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-progress.ps1 -ResetState -TimeoutSeconds 20
```

## interactive-win11-resize.ps1

Interactive Win11 validation for resize repaint coverage. It launches
`winghostty` with a light terminal background, synthesizes a live resize
growth, exits the resize loop, captures the settled enlarged window, and fails
if the newly exposed right or bottom content bands are mostly near-black or
unpainted neutral gray.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-resize.ps1 -ResetState -TimeoutSeconds 15
```

## interactive-win11-undo.ps1

Interactive Win11 validation for the shipped undo/redo action set. It launches
`winghostty`, exercises split creation, tab close/restore, and empty-host
survival after last-tab close, then verifies the visible tab/surface counts
after each replay step. Last-tab headless undo/redo remains covered by focused
Zig tests plus manual validation; this harness does not claim foreground
keyboard coverage.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-undo.ps1 -ResetState -TimeoutSeconds 35
```

## ..\..\scripts\interactive-win11.ps1

Generic repo-local Win11 launcher for ad hoc debugging. It uses the
same sandbox/bootstrap logic as the focused harnesses and can either
launch `winghostty` directly or open a shell with the sandbox
environment applied.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ..\..\scripts\interactive-win11.ps1 -ResetState
```

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads ghostty.dll
at runtime and calls ghostty_info + ghostty_init to verify the MSVC C
runtime is properly initialized.

### Build

First build ghostty.dll, then compile the test:

```powershell
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

From this directory:

```powershell
copy ..\..\zig-out\lib\ghostty.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```text
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".
