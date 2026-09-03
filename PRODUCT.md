# Product

This page defines what noctty is for and how product decisions get
judged. The visual and interaction contract that implements these
principles lives in [DESIGN.md](DESIGN.md).

## Users

noctty is for keyboard-first Windows developers who move between
PowerShell and WSL, keep several tabs and panes open, run long-lived
shells and TUIs, expect their session layout to survive restarts, and
reach the remote hosts in their SSH config. The canonical benchmark
user values native Windows behavior, immediate feedback, and deep
terminal capability more than cross-platform uniformity. Remote scope
stays lean: noctty surfaces and launches the user's own `ssh`; it
does not bundle SSH clients, secret vaults, or fleet-management tools.

The session promise is tiered: layout survives restarts (shipped),
pane contents come back as clearly-marked snapshots (shipped, opt-in), and
process durability — shells that outlive the window — is a named
aspiration, pursued only as feasibility work validates it.

## Product purpose

noctty exists to provide the fastest, most fluid native terminal
workflow for Windows developers. Success means PowerShell, WSL, tabs,
splits, search, session restoration, and keyboard navigation all feel
instantaneous and dependable, while keeping Ghostty's terminal core and
compatibility intact.

## Performance budgets

"Fastest, most fluid" is a measurable contract, not a slogan. These are
the targets; the measured baseline is in
[docs/windows-benchmark-methodology.md](docs/windows-benchmark-methodology.md).
The interactive figures below come from a run that predates the most
recent code reorganization and are awaiting re-measurement, which that
document records:

- Cold start to first frame: under 300 ms. Measured 297 ms median,
  313 ms p95 — the median meets the target and the tail does not.
- Key-to-pixel latency: at most one frame at 60 Hz beyond the OS
  input/compositor floor. Not yet measured; the suite ships a software
  proxy and a documented camera/photodiode procedure, neither of which
  certifies this budget.
- Memory: under 20 MB steady-state per additional pane. Measured
  32.14 MB median of whole-process private bytes, which includes
  OpenGL driver commit and is not apportioned. Target unchanged.
- Idle: effectively 0% GPU/CPU with no timer wake churn. Measured 0%
  CPU, 0% GPU, and zero successful swaps over a 10 s idle interval. See
  [Windows power and battery behavior](docs/windows.md#power-and-battery).

The benchmark suite (roadmap C01) defines the measurement methodology,
workload, baseline machine, and tolerances. CI gates the headless
throughput floor today; the interactive thresholds remain provisional
and inactive until their percentiles and tolerances are reviewed.

## Brand personality

Native, credible, precise. The interface should stay calm during
sustained work and clear when something fails, without pulling attention
away from terminal content.

References:

- Windows for platform behavior, accessibility, input, and system
  integration.
- Visual Studio Code for dense workspace clarity.
- Raycast for keyboard speed and command discovery.

## Anti-references

- A Windows Terminal clone differentiated only by styling.
- A generic Ghostty parity fork that treats Windows as another platform
  skin.
- Decorative glass, neon, oversized chrome, or animation without state
  meaning.
- Hidden state, novelty controls, and pointer-only workflows.
- Feature-count competition that weakens performance or reliability.

## Design principles

1. Terminal content comes first. Chrome has to justify every pixel and
   every repaint.
2. Frequent actions stay direct, keyboard-first, and discoverable
   without onboarding gates.
3. Be native where behavior matters: follow Windows conventions for
   focus, input, accessibility, windowing, menus, and recovery.
4. Keep focus, selection, progress, and failure visible without visual
   noise.
5. Treat reliability as a feature: preserve user state, fail visibly,
   and always leave a path back to a working terminal.
6. Compete on every path into a terminal, not just the window once
   open: default-terminal handoff, jump lists, Explorer entry, and
   global summon are product surface, and each must behave natively.

## Accessibility & inclusion

Application chrome targets WCAG 2.2 AA-equivalent contrast and full
keyboard operation; the complete accessibility targets are defined in
[DESIGN.md](DESIGN.md#accessibility-targets).
