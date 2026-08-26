# Terminal accessibility and Settings theme regression plan

Status: approved for execution.

Date: 2026-07-23.

Base: `3f0a928c5ee5bb5dcf52c32547a406363c4d53de`.

## Objective

Close two release-blocking human-test failures without weakening native Windows
behavior:

1. Narrator must enter and read terminal text, not only announce the tab or
   document title. A pane or tab that receives focus after background output
   must expose current text and geometry on the first focused query.
2. Changing `Window theme` from System to Dark in Settings must produce an
   immediate, visible, reversible preview in terminal chrome and the Settings
   window. High Contrast must continue to use Windows system colors.

The release remains blocked until the deterministic gates pass and a human
Narrator/NVDA cell confirms usable speech and navigation.

## Evidence

### Terminal accessibility

- `src/apprt/win32_uia/widgets.zig:2292-2303` returns an empty legacy
  `ITextProvider::GetSelection` array for terminal documents.
- `src/apprt/win32_uia/widgets.zig:2361-2372` advertises
  `SupportedTextSelection_None`.
- `src/apprt/win32_uia/widgets.zig:2423-2447` simultaneously exposes the real
  caret through TextPattern2 `GetCaretRange`.
- `test/windows/interactive-win11-accessibility.ps1:1392-1398` currently locks
  in the empty-selection behavior.
- `src/apprt/win32.zig:24878-24922` ties accessible-snapshot publication to
  renderer refresh and listener/query activity.
- `src/apprt/win32.zig:27175-27186` publishes terminal focus without first
  forcing the retained snapshot current.
- Human repro: Narrator announces tab/document titles but not terminal content;
  background output joins its visual bounding box only after a pane/tab focus
  round trip.
- Microsoft Terminal is the compatibility oracle: it exposes one degenerate
  cursor range through legacy `GetSelection` and advertises single selection.
- Microsoft Terminal also exposes `LiveSetting=Polite` and sends sanitized new
  terminal output through `UiaRaiseNotificationEvent` with
  `NotificationProcessing_All`, suppressing unreadable output and key echoes.

### Theme preview

- `src/apprt/win32_settings.zig:2538-2553` correctly stages
  `window-theme` with `live_preview=true`.
- `src/apprt/win32.zig:17587-17623` correctly updates the live config and calls
  `reconfigureTheme`.
- `src/apprt/win32.zig:5476-5514` rebuilds host resources, but queues a host
  chrome repaint only when frame mode changes; ordinary System-to-Dark swaps
  can retain stale pixels.
- `src/apprt/win32_settings.zig:5086-5106` paints the Settings client area with
  unconditional `COLOR_BTNFACE` and `COLOR_WINDOW`.
- `src/apprt/win32_settings.zig:1998-2002` invalidates Settings on theme change
  but does not apply dark DWM/native-control theming.
- Human repro: selecting Dark is announced but does not visibly darken the
  foreground Settings experience.

## Architecture decision

### Terminal accessibility session

Create one deep `TerminalAccessibilitySession` module at the Surface/UIA seam.
Its narrow interface owns:

- provider acquisition for `WM_GETOBJECT`;
- immutable terminal snapshot cache;
- query-triggered refresh scheduling;
- activation/focus refresh;
- timer handling;
- TextChanged and caret event policy;
- polite live-setting metadata and bounded new-output notification policy;
- provider detach and lifetime.

Its implementation may use the existing terminal-text adapter and UIA provider,
but callers must not know timer IDs, query windows, listener predicates, cache
locks, or event selection. Renderer repaint remains an input signal, not the
semantic ownership boundary.

The canonical caret is one state value consumed by both:

- legacy TextPattern `GetSelection`; and
- TextPattern2 `GetCaretRange`.

This creates depth, improves locality, and prevents the current interface drift.
It is a replace-not-layer refactor: delete superseded Surface/context scheduling
code as the module takes ownership.

### Window theme adapter

Deepen `win32_theme` behind one window-kind-aware implementation for host and
Settings windows. The interface consumes resolved theme and High Contrast state
and owns:

- DWM light/dark attributes;
- native control theme application;
- semantic Settings brushes and control colors;
- complete host/child invalidation after a theme-resource swap;
- High Contrast fallback to Windows system colors.

Settings transaction code keeps emitting typed live-preview effects. It does
not learn DWM, brush, repaint, or control-tree details.

## Implementation sequence

### 1. Correct the canonical caret contract

- For terminal role, return one immutable degenerate range at the cached caret
  from legacy `GetSelection`.
- Advertise `SupportedTextSelection_Single`.
- Make terminal range `Select` behavior contract-consistent and harmless; do
  not mutate PTY state merely to satisfy UIA.
- Reuse the same snapshot/caret normalization as TextPattern2.
- Replace tests that require `None`/zero ranges with parity assertions between
  legacy selection and TextPattern2 caret.

### 2. Extract and wire `TerminalAccessibilitySession`

- Move `TerminalUiaContext`, retained cache, query timestamps, refresh timer,
  publication policy, and event selection out of `win32.zig`.
- Give `Surface` one session field and lifecycle calls only.
- Force a bounded current snapshot before publishing terminal focus/activation.
- Keep event emission listener-gated and coalesced.
- Preserve lock order: renderer snapshot first, release renderer lock, then
  publish under session cache lock.
- Preserve cold-query timeout and detached-provider behavior.
- Delete the old split ownership and implementation-name source-regex checks.

### 3. Add Windows-Terminal-compatible spoken output

- Expose the terminal as the platform-compatible Text control/localized
  `terminal` role where required by the provider contract.
- Return `LiveSetting=Polite`.
- Keep TextChanged and TextSelectionChanged for range invalidation/caret state.
- Feed only newly produced readable terminal output to a bounded,
  UI-thread-safe notification queue.
- Suppress matching echoed key input and control-only/unreadable output.
- Raise `UiaRaiseNotificationEvent` with an activity identifier dedicated to
  terminal output and a processing mode that preserves command output order
  while allowing keyboard input to interrupt speech.
- Never announce the full retained snapshot for each change.
- Coalesce chunks without merging unrelated command boundaries or allowing an
  unbounded backlog.

### 4. Complete host theme repaint ownership

- Make `App.reconfigureTheme` always queue the known full chrome/control repaint
  after replacing theme resources.
- Retain live-resize coalescing and avoid synchronous repaint storms.
- Ensure discard/revert crosses the same path and restores pixels immediately.

### 5. Add the Settings window theme adapter

- Resolve semantic Settings colors from app theme outside High Contrast.
- In High Contrast, preserve current `GetSysColor` behavior exactly.
- Apply the appropriate DWM titlebar and native-control theme to the Settings
  HWND and control tree.
- Handle `WM_CTLCOLORSTATIC`, `WM_CTLCOLORBTN`, `WM_CTLCOLOREDIT`, and related
  combo/list children through cached semantic brushes where Win32 requires it.
- Recreate/delete cached brushes on theme transition and teardown.
- Keep focus, disabled, validation, and selection states readable; do not
  owner-draw standard controls unless native theming cannot meet contrast.

### 6. Close the false-green test gaps

Unit/provider tests:

- legacy terminal `GetSelection` returns one degenerate caret range;
- legacy and TextPattern2 caret offsets are equal;
- SupportedTextSelection is Single;
- selection calls are safe and detached providers fail correctly;
- session focus refresh decision and event coalescing;
- terminal LiveSetting, notification metadata, key-echo suppression,
  readability filtering, chunk bounds, and ordering;
- semantic Settings color mapping for light, dark, system, and High Contrast;
- theme-resource replacement implies invalidation.

Interactive Windows 11 tests:

- produce output in an unfocused pane, focus it once, and verify the first
  acquired focused range contains the output without a pre-registered
  TextChanged listener;
- verify existing TextPattern objects refresh without requiring a second focus
  switch;
- verify legacy selection can expand/read the current line;
- select forced Dark in Settings and sample stable host and Settings client
  pixels until both change;
- discard, verify both pixels restore, and verify config remains unchanged;
- enable High Contrast and verify Settings uses system colors rather than
  app-theme colors.

Manual acceptance:

- Narrator reads existing terminal content after entering a pane;
- Narrator announces new output at a usable cadence without duplicate speech;
- Narrator/NVDA can navigate current and prior terminal lines;
- background pane/tab output is current on first focus;
- NVDA review cursor works;
- Settings Dark preview and discard are immediate at 100%, 200%, and 300%;
- High Contrast remains legible and reversible.

## Rejected alternatives

- Raising a notification with the full terminal snapshot on every TextChanged:
  duplicates speech, destroys command boundaries, and creates an unbounded
  output cadence. Use the Windows Terminal new-output contract instead.
- Unconditional UIA snapshot on every render: defeats the existing idle-cost
  boundary.
- A parent-background-only dark Settings patch: leaves controls/titlebar
  visually incoherent.
- A new cross-platform accessibility abstraction: no second implementation or
  caller; the real seam is Win32 Surface/UIA lifecycle.

## Validation commands

Use the repository Windows wrapper where applicable.

```powershell
scripts/dev-windows.cmd zig fmt --check src/apprt
scripts/dev-windows.cmd zig build test -Dtest-filter=TerminalProvider
scripts/dev-windows.cmd zig build test -Dtest-filter=terminal_UIA
scripts/dev-windows.cmd zig build test -Dtest-filter=win32_settings
scripts/dev-windows.cmd zig build -Demit-exe=true
pwsh -NoProfile -File test/windows/interactive-win11-accessibility.ps1 -ResetState -ExecutablePath <exact-artifact>
```

Then run the repository full test and exact-SHA interactive composite gates
used for release.

## Completion gates

- [ ] Canonical caret exposed through legacy TextPattern and TextPattern2.
- [ ] Focus/activation publishes a current snapshot before focus event.
- [ ] Polite live metadata and sanitized, bounded new-output notifications
      provide incremental screen-reader speech without echoed key duplication.
- [ ] Terminal accessibility lifecycle has one deep module and old duplicate
      ownership is deleted.
- [ ] System-to-Dark preview repaints terminal chrome immediately.
- [ ] Settings HWND and native controls visibly preview explicit Dark.
- [ ] High Contrast preserves Windows system colors.
- [ ] Preview discard restores pixels and leaves persisted config unchanged.
- [ ] Unit/provider and interactive regressions pass.
- [ ] Independent Sol audit has no actionable finding.
- [ ] One bounded Fable re-audit has no actionable finding.
- [ ] Human Narrator and NVDA acceptance cells pass.

## Residual risks

- Narrator’s exact legacy-caret heuristic is not a documented guarantee; human
  retest remains mandatory.
- Native dark theming varies by Windows build; the supported Windows 11 matrix
  must validate titlebar, combos, edit fields, disabled controls, and focus.
- Moving session ownership is concurrency-sensitive. Lock-order and provider
  teardown tests are mandatory.
- Speech-output automation is not a substitute for a human screen-reader pass.
