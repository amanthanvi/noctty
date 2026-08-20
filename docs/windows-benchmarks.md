# Windows benchmarks

Published, same-machine Windows numbers for winghostty. PRODUCT.md
budgets stay **provisional** until the first baseline against Windows
Terminal, Alacritty, Tabby, and Wave on one machine.

## Provisional budgets

- Cold start to first frame: under 300 ms.
- Key-to-pixel latency: at most one frame at 60 Hz beyond the OS
  input/compositor floor.
- Memory: under 20 MB steady-state per additional pane.
- Idle: effectively 0% GPU/CPU with no timer wake churn.

CI regression gates attach to these numbers only after that first
baseline is checked in. Until then, the harness records artifacts; it
does not fail the build on budget miss.

## Harness

```powershell
scripts\dev-windows.cmd powershell -NoProfile -File scripts\bench-windows.ps1
```

Optional:

```powershell
scripts\bench-windows.ps1 -Exe .\zig-out\bin\winghostty.exe -Runs 5
```

`bench-windows.ps1` measures **cold start**: process create to first
visible top-level HWND (`winghostty.win32.host`), plus working-set after
a short settle. It writes JSON under `.sandbox\win11\bench\`.

## Metrics not in this harness

These stay documented so a later same-machine run can fill them:

| Metric | Method |
| --- | --- |
| Key-to-pixel | Camera or photodiode against a known glyph flash; subtract OS input/compositor floor |
| ConPTY round-trip | Echo a marker through the child and timestamp first paint |
| Scroll MB/s | Large `type` / `Get-Content` dump; bytes / elapsed |
| Frame-time p95 | Existing `+boo` / interactive paint-gap harnesses |
| Idle GPU/CPU | Perf counters after 10 s with no input |

Do not compare numbers across machines or GPU vendors. Publish the
machine SKU, GPU, driver, and OS build with every result row.
