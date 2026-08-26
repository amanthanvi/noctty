# ConPTY ownership and mangling catalog (C05)

winghostty creates PTYs through `CreatePseudoConsole`. The in-box
Windows conhost only forwards VT it recognizes and silently drops the
rest — Kitty APC and Sixel DCS are the measured casualties.

## Bundled OpenConsole

Place the Microsoft ConPTY redistributable pair beside `winghostty.exe`:

- `conpty.dll`
- `OpenConsole.exe` (matching architecture)

Startup `LoadLibrary`s `CreatePseudoConsole` / `ResizePseudoConsole` /
`ClosePseudoConsole` from that adjacent `conpty.dll` so in-box
`kernel32` cannot ignore the side-by-side pair. When the pair is
absent or the exports are missing, the process uses in-box `kernel32`
and logs a degraded-mode warning that names Kitty/Sixel loss. This
repo does not vendor the Microsoft binaries; release packaging can
stage a version-pinned pair when the redistributable license is
attached.

## Mangling catalog

| Sequence / behavior | In-box conhost | Bundled OpenConsole (current Microsoft redistributable) | Mitigation |
| --- | --- | --- | --- |
| Kitty graphics (APC) | Often stripped | Passed through on recent OpenConsole | Bundle `conpty.dll` |
| Sixel (DCS) | Often stripped | Passed through on recent OpenConsole | Bundle `conpty.dll` |
| Mid-DCS SGR reset injection | Observed; unmitigated | Still possible | None yet; log + catalog |
| OSC 10/11/12 color query | May be rewritten | Host-dependent | Prefer core palette, not queries |
| Window title OSC 0/2 | Passed | Passed | None |
| OSC 133 / OSC 9;9 shell marks | Passed | Passed | None |
| Synchronized output `2026h/l` | Passed when recognized | Passed | Force renderer wake on `2026l` |

Measured esctest baselines stay in
[windows-vt-conformance.md](windows-vt-conformance.md). Re-run after
changing the bundled OpenConsole version.

## Degraded-mode log line

```
using OS conhost (Kitty graphics and Sixel may be stripped); place conpty.dll + OpenConsole.exe beside the exe to prefer bundled ConPTY
```
