# Windows VT Conformance

`+vt-probe` is a deterministic capability inventory. It distinguishes shared
parser/core support from behavior that has also been validated through the
Win32 runtime.

Each capability line includes:

- `category`: protocol family (`terminfo`, `osc`, `csi`, or `graphics`).
- `direction`: whether winghostty advertises, parses, or parses and emits it.
- `win32-runtime`: Win32 validation status.
- `evidence`: harness or test family behind the status.

`win32-runtime` values:

- `validated`: an interactive Win32 harness exercises the protocol behavior.
- `parser-only`: parser/core support is known, but no Win32 GUI behavior is
  validated.
- `pending`: practical Win32 runtime coverage is still missing.
- `not-applicable`: the claim is not a runtime protocol behavior.

Current practical Win32 coverage:

- OSC 9 desktop notification and OSC 133 command-finish state:
  `test/windows/interactive-win11-command-finish.ps1`
- OSC 9;4 taskbar progress:
  `test/windows/interactive-win11-progress.ps1`
- CSI ?2026 synchronized output repaint behavior:
  `test/windows/interactive-win11-boo-performance.ps1`

Run the fast metadata validator:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\test\windows\vt-probe-win32-conformance.ps1 -ResetState -TimeoutSeconds 10
```

Run the metadata validator plus the referenced Win32 runtime harnesses:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\test\windows\vt-probe-win32-conformance.ps1 -ResetState -Runtime
```

Known runtime gaps are intentionally visible in `+vt-probe`: OSC 7 cwd state,
OSC 8 link interaction, OSC 52 clipboard prompts/reads/writes, color rendering
for OSC 4 / 10 / 11 / 21, and Kitty graphics pixel validation do not yet have
dedicated Win32 GUI harnesses.
