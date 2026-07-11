# Product

## Register

product

## Users

winghostty is for keyboard-first Windows developers who move between
PowerShell and WSL, keep several tabs and panes open, run long-lived shells
and TUIs, and expect their session layout to survive restarts. The canonical
benchmark user values native Windows behavior, immediate feedback, and deep
terminal capability more than cross-platform uniformity.

## Product Purpose

winghostty exists to provide the fastest, most fluid native terminal workflow
for Windows developers. Success means PowerShell, WSL, tabs, splits, search,
session restoration, and keyboard navigation feel instantaneous and dependable
while retaining Ghostty's terminal core and compatibility.

## Brand Personality

Native, credible, precise. The interface should feel calm under sustained work,
clear under failure, and confident without calling attention away from terminal
content.

References:

- Windows for platform behavior, accessibility, input, and system integration.
- Visual Studio Code for dense workspace clarity.
- Raycast for keyboard speed and command discovery.

## Anti-references

- A Windows Terminal clone differentiated only by styling.
- A generic Ghostty parity fork that treats Windows as another platform skin.
- Decorative glass, neon, oversized chrome, or animation without state meaning.
- Hidden state, novelty controls, and pointer-only workflows.
- Feature-count competition that weakens performance or reliability.

## Design Principles

1. **Terminal content dominates.** Chrome earns every pixel and every repaint.
2. **Flow over ceremony.** Frequent actions stay direct, keyboard-first, and
   discoverable without onboarding gates.
3. **Native where behavior matters.** Follow Windows conventions for focus,
   input, accessibility, windowing, menus, and recovery.
4. **Quiet but unmistakable state.** Focus, selection, progress, and failure are
   always clear without visual noise.
5. **Reliability is a product feature.** Preserve user state, fail visibly, and
   provide a safe path back to a working terminal.

## Accessibility & Inclusion

Target WCAG 2.2 AA-equivalent contrast and interaction behavior for application
chrome. Support complete keyboard operation, visible focus, Windows High
Contrast, reduced motion, color-blind-safe semantic states, UI Automation, and
100–300% DPI. Validate with Narrator and NVDA. Pointer actions require a
keyboard or command-palette equivalent.
