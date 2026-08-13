# Product

This page defines what winghostty is for and how product decisions get
judged. The visual and interaction contract that implements these
principles lives in [DESIGN.md](DESIGN.md).

## Users

winghostty is for keyboard-first Windows developers who move between
PowerShell and WSL, keep several tabs and panes open, run long-lived
shells and TUIs, and expect their session layout to survive restarts. The
canonical benchmark user values native Windows behavior, immediate
feedback, and deep terminal capability more than cross-platform
uniformity.

## Product purpose

winghostty exists to provide the fastest, most fluid native terminal
workflow for Windows developers. Success means PowerShell, WSL, tabs,
splits, search, session restoration, and keyboard navigation all feel
instantaneous and dependable, while keeping Ghostty's terminal core and
compatibility intact.

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

## Accessibility & inclusion

Application chrome targets WCAG 2.2 AA-equivalent contrast and full
keyboard operation; the complete accessibility targets are defined in
[DESIGN.md](DESIGN.md#accessibility-targets).
