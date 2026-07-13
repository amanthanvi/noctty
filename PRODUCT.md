# Product

This page defines what winghostty is for and how product decisions get
judged. The visual and interaction contract that implements these
principles lives in [DESIGN.md](DESIGN.md).

## Users

winghostty is for keyboard-first Windows developers who move between
PowerShell and WSL, keep several tabs and panes open, run long-lived shells
and TUIs, and expect their session layout to survive restarts. The canonical
benchmark user values native Windows behavior, immediate feedback, and deep
terminal capability more than cross-platform uniformity.

## Product Purpose

winghostty exists to provide the fastest, most fluid native terminal
workflow for Windows developers. Success looks like this: PowerShell, WSL,
tabs, splits, search, session restoration, and keyboard navigation feel
instantaneous and dependable — while Ghostty's terminal core and
compatibility stay intact.

## Brand Personality

Native, credible, precise. The interface should feel calm under sustained
work, clear under failure, and confident without calling attention away from
terminal content.

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

## Design Principles

1. **Terminal content dominates.** Chrome earns every pixel and every
   repaint.
2. **Flow over ceremony.** Frequent actions stay direct, keyboard-first, and
   discoverable without onboarding gates.
3. **Native where behavior matters.** Follow Windows conventions for focus,
   input, accessibility, windowing, menus, and recovery.
4. **Quiet but unmistakable state.** Focus, selection, progress, and failure
   are always clear without visual noise.
5. **Reliability is a product feature.** Preserve user state, fail visibly,
   and provide a safe path back to a working terminal.

## Accessibility & Inclusion

Application chrome targets WCAG 2.2 AA-equivalent contrast and full keyboard
operation; the complete accessibility targets are defined in
[DESIGN.md](DESIGN.md#accessibility-targets).
