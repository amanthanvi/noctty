# Product

This page defines what winghostty is for and how product decisions get
judged. The visual and interaction contract that implements these
principles lives in [DESIGN.md](DESIGN.md).

## Users

winghostty is for keyboard-first Windows developers who move between
PowerShell and WSL, keep several tabs and panes open, run long-lived
shells and TUIs, expect their session layout to survive restarts, and
reach the remote hosts in their SSH config. The canonical benchmark
user values native Windows behavior, immediate feedback, and deep
terminal capability more than cross-platform uniformity. Remote scope
stays lean: winghostty surfaces and launches the user's own `ssh`; it
does not bundle SSH clients, secret vaults, or fleet-management tools.

The session promise is tiered: layout survives restarts (shipped),
pane contents come back as clearly-marked snapshots (next), and
process durability — shells that outlive the window — is a named
aspiration, pursued only as feasibility work validates it.

## Product purpose

winghostty exists to provide the fastest, most fluid native terminal
workflow for Windows developers. Success means PowerShell, WSL, tabs,
splits, search, session restoration, and keyboard navigation all feel
instantaneous and dependable, while keeping Ghostty's terminal core and
compatibility intact.

## Performance budgets

"Fastest, most fluid" is a measurable contract, not a slogan. Budgets
(provisional until the benchmark suite's first same-machine baseline
run fixes them; CI gates against them once measured):

- Cold start to first frame: under 300 ms.
- Key-to-pixel latency: at most one frame at 60 Hz beyond the OS
  input/compositor floor.
- Memory: under 20 MB steady-state per additional pane.
- Idle: effectively 0% GPU/CPU with no timer wake churn.

The benchmark suite (roadmap C01) defines the measurement methodology,
workload, baseline machine, and tolerances; CI gates activate once that
suite lands its first same-machine baseline.

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
