# Stall watch and injected-load A/B (measurement only, not for merge)

This scratch harness compared UI stalls between renderer pacing (PR #639, measured at 829bfd98c) and main (cec863455) on 2026-10-31. The finding and its rules are in the 2026-10-31 STALL-LOAD-AB-01 entry in `docs/agents/log/test-harnesses.md`. The files are kept as they ran, with absolute temp paths rewritten to `$env:TEMP`. Expect to adjust paths before running them again.

## What it needs

- The lat02 probe and its helpers (`lat-echo.c`, the trace patch for the builds) from `origin/lat02-measurement-harness` and `origin/lat01-measurement-harness`. See the 2026-10-31 MEASUREMENT-HARNESS-RERUN-01 entry.
- Two trace-patched ReleaseFast builds. Keep each build's `noctty.pdb` beside its exe: without it, cdb shows noctty frames as bare offsets.
- `cdb.exe` from the Windows SDK, for the stacks.

## Pieces

- `harness/runner-stall2.ps1` is a copy of the lat02 runner with three additions:
  - a quiet gate before each run: machine busy under 25% for 10 s;
  - a build-process sentinel, logging name and PID only;
  - the watchdog started beside each probe.
- `harness/probe.ps1` is the lat02 probe. It runs noctty on a private desktop (`CreateDesktopW`, with `lpDesktop` on every child).
- `watchdog.ps1` and `StallWatch.cs`:
  - Every 100 ms it sends `SendMessageTimeoutW(WM_NULL, SMTO_ABORTIFHUNG, 250 ms)` to the run's noctty window.
  - It logs, for every noctty thread, the state, wait reason, and current and base priority.
  - It logs machine busy and the top 5 processes, by name and PID only.
  - On the first reply over 1 s it takes two `cdb -pv` stack dumps. Note that the attach itself suspends the target for 0.6-2.4 s.
- `load/CpuLoad.cs` is the injected load: one spinning thread per logical processor, at BelowNormal, busy 2.0 s then idle 4.0 s. It logs each burst's QPC start and end.
- `harness/probe-load.ps1` adds an `Idle` priority choice to the probe, through the job object's priority-class limit `0x40`. `harness/runner-load.ps1` starts and stops the load around each probe and samples priorities.
- `control/` holds two controls:
  - the watchdog's positive control: a WinForms window whose UI thread sleeps 3 s;
  - the load's control: an Idle-class iteration counter, and a Normal window's round trip during bursts.
- `harness/analyze_*.py` and `harness/table_load.py` do the per-run, per-burst and per-side summaries.

## Results kept here

- `runs/quiet-table.txt`: the quiet set, 19 main runs and 20 pacing runs.
- `runs/load-table.txt`: per-run results under the load, 20 ABBA pairs.
- `runs/load-per-burst.txt`: per-burst results under the load.

The full per-key and per-event logs are not kept, because they name the other processes that were running on the maintainer's machine.
