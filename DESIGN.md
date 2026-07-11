# winghostty Design System

This is the target visual and interaction contract for winghostty's native
Windows shell. Existing implementation tokens remain authoritative until a
surface is migrated; new work should converge on this contract without
regressing platform behavior or accessibility.

## Direction

Compact, adaptive, and terminal-first. The physical scene is a developer moving
between a bright office, a dim home workspace, and mixed-DPI monitors while a
long-running PowerShell or WSL session remains visible. Therefore light, dark,
system, and High Contrast modes are equal product states—not variants of one
preferred theme.

Color strategy: restrained. Neutral chrome carries the interface; Windows
accent and semantic colors communicate selection, focus, warning, and failure.
No decorative glass or persistent color fields.

## Foundations

### Typography

- UI family: Segoe UI Variable where available, then Segoe UI.
- Terminal font: user-configured and independent from shell chrome.
- UI scale: 12 px secondary labels, 13 px controls/body, 14 px emphasized body,
  16 px section titles, 20 px exceptional dialog titles.
- Weights: 400 regular, 600 semibold. Avoid display weights and all-caps labels.
- Prose measure: 65–75 characters. Dense lists may use available width.

### Spacing and geometry

- Base unit: 4 px; allowed micro-step: 2 px.
- Control heights: 28 px compact, 32 px standard, 36 px touch-friendlier.
- Chrome padding: 8 px standard; 12–16 px for dialogs and settings panes.
- Corners: 4 px controls, 6 px overlays, 8 px dialogs. Use native window
  corners where Windows owns the frame.
- Borders: 1 px separators and control frames. Active pane: a thin semantic
  focus indicator, not a persistent header.
- Minimum pointer target: 32×32 px in dense chrome; 44×44 px where touch is a
  primary interaction.

### Color roles

Current RGB values in `src/apprt/win32_theme.zig` seed the system. Preserve role
names rather than copying literal colors into components.

| Role              | Light seed | Dark seed | Use                                     |
| ----------------- | ---------- | --------- | --------------------------------------- |
| Chrome background | `#F3F3F3`  | `#181818` | Window shell and tab strip              |
| Elevated surface  | `#F9F9F9`  | `#1C1C1E` | Palette, menus, settings panes          |
| Primary text      | `#1B1B1B`  | `#DCDCE0` | Labels and primary content              |
| Secondary text    | `#606060`  | `#9E9EA4` | Hints and metadata                      |
| Accent            | `#0078D4`  | `#749CE0` | Focus, active selection, primary action |
| Error             | `#C42B1C`  | `#FF8484` | Errors and destructive outcomes         |

- Body text contrast: at least 4.5:1.
- Large text and essential non-text/focus indicators: at least 3:1.
- Never use color as the only state cue.
- High Contrast uses system colors and suppresses nonessential custom styling.

## Components

Every interactive component defines default, hover, focused, pressed, selected,
disabled, loading, warning, and error behavior where applicable. Focus is never
represented by hover styling.

### Tabs and panes

- One adaptive tab row with readable minimum widths and searchable overflow.
- Preserve the active and recently used tabs longest during compression.
- Active tab treatment is restrained but visible in active and inactive
  windows.
- Active pane uses a thin accent indicator. Direction and size labels appear
  only while navigating or resizing.
- Drag previews appear only during drag and name the resulting operation.
- Split dividers maximize hit target without increasing painted thickness.

### Universal palette

- Single search field and blended result list, with discoverable scoped filters.
- Rows expose title, category, description, shortcut, disabled reason, and
  destructive status as needed.
- Selection, query changes, empty results, and execution outcomes are announced
  through UI Automation.
- Dedicated scrollback search remains a separate task surface.

### Settings

- Stable left rail: Appearance, Terminal, Shell, Privacy, Updates, Keybindings,
  Advanced.
- Inline validation and conflict resolution take precedence over modal dialogs.
- Reversible appearance changes may preview immediately; behavioral changes
  remain staged until Apply.
- Advanced always exposes the plain-text configuration escape hatch and a
  source-preserving diff.

### Feedback and recovery

- Banners are local, concise, and actionable; toasts are supplementary.
- Destructive actions name what will be lost and require an explicit action.
- Recovery surfaces favor: retry normally, launch safely, inspect quarantined
  data, open settings/config, export diagnostics.
- Empty states teach the next useful action rather than merely reporting
  absence.

## Motion

- Default duration: 120–200 ms; 240 ms maximum for large spatial transitions.
- Ease out with a quart/quint curve. No bounce or elastic motion.
- Animate compositor-friendly properties; do not animate terminal geometry when
  it delays viewport correctness.
- Motion communicates selection, focus transfer, reveal, dismissal, drag, or
  completion—never decoration.
- Reduced Motion makes transitions instant or uses a minimal crossfade.
- Settled UI has no animation or rendering heartbeat.

## Windows adaptation

- Windows 11 may use supported backdrop, corner, Snap Layout, and composition
  capabilities when they improve hierarchy.
- Windows 10 uses polished solid surfaces with identical geometry, workflows,
  and information.
- Native semantics win over visual uniformity for menus, IME, focus, keyboard
  navigation, touch, DPI, system theme, and accessibility.
- Device or composition failure must retain a readable native recovery path.

## Verification

Golden captures cover Windows 10/11, light/dark/system/High Contrast,
100/150/200/300% DPI, 60/120 Hz, active/inactive windows, all component states,
overflow, nested splits, palette, settings, drag previews, and recovery.

Reject clipping, overlap, stale pixels, ambiguous focus, hidden state, or
terminal viewport loss. Pair visual checks with keyboard traversal, UI
Automation inspection, Narrator, NVDA, reduced-motion, and contrast validation.
