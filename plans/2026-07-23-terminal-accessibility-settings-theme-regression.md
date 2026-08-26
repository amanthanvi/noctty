# Terminal accessibility and Settings theme regression plan

Status: follow-up in progress. Targeted unit/provider tests, focused native
key-input scenarios, flagship contracts, a full Zig suite, and the full
accessibility harness passed before the latest audit. Verifier follow-up and
the output-architecture redesign are now source-complete: committed terminal
output is emitted at the authoritative `StreamHandler`/parser seam and the raw
Win32 VT re-parser is deleted. Focused semantic-output, transport, and
announcement tests pass, and independent source implementation,
semantic/deslop, and existing flagship-contract audits are clean. The final
semantic-interest contract refresh, unified executable build, and full Zig
suite also pass. The final automated live accessibility/theme/High
Contrast/scaling/idle harness passes. Release workflow gates and human
Narrator/NVDA acceptance remain pending.

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
Settings windows. `WindowThemeAdapter` consumes resolved theme and High
Contrast state and owns:

- DWM light/dark attributes;
- native control theme application;
- High Contrast fallback to Windows system colors.

`win32_settings.SettingsThemeAdapter` retains local ownership of semantic
colors, GDI brushes, reentry protection, teardown, child theming, and complete
Settings repaint. Host theme replacement retains host repaint ownership.
Settings transaction code only emits typed live-preview effects.

## Implementation sequence

### 1. Correct the canonical caret contract

- For terminal role, return one immutable degenerate range at the cached caret
  from legacy `GetSelection`.
- Advertise `SupportedTextSelection_Single`.
- Return `E_NOTIMPL` from terminal range `Select`; the immutable degenerate
  caret remains readable/expandable without claiming a mutable selection.
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
- Emit committed semantic terminal output from the authoritative
  `StreamHandler`/parser seam after parsing and the render decision complete;
  offer only that output to the Surface-owned `TerminalOutputTransport`.
- Keep the producer interest-gated, allocation-free, and nonblocking. The fixed
  eight-by-1000-byte transport never enters the global app mailbox; contention
  or capacity exhaustion becomes one ordered omission barrier.
- Drain retained chunks plus the omission marker on the Win32 UI thread into
  `TerminalAccessibilitySession`; its bounded notification FIFO owns
  echo suppression and speech ordering. Snapshot refresh and provider queries
  never derive, consume, or clear speech.
- Keep the raw Win32 VT/control re-parser deleted. Control-string, C1,
  malformed-sequence, and parser resynchronization behavior belongs to the
  authoritative terminal parser, not a second accessibility state machine.
- Suppress matching echoed key input and control-only/unreadable output.
- Raise `UiaRaiseNotificationEvent` with the dedicated `TerminalTextOutput`
  activity identifier and `NotificationProcessing_All` (`2`) so rapid terminal
  chunks remain ordered. Sparse command-palette/status notifications continue
  to use `NotificationProcessing_MostRecent` (`3`).
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
- terminal LiveSetting, notification metadata, rapid ordered delivery,
  key-echo suppression, readability filtering, and chunk bounds;
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
- keyboard input can interrupt ongoing speech without dropping queued output;
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
pwsh -NoProfile -File test/windows/interactive-win11-accessibility.ps1 -ResetState -TimeoutSeconds 20 -IdleSoakSeconds 60
```

The final validation ran the repository full Zig suite, focused native
key-input scenarios, and the full accessibility harness. This plan does not
claim a pass for the broader interactive composite suite.

## Completion gates

- [x] Canonical caret exposed through legacy TextPattern and TextPattern2.
- [x] Focus/activation publishes a current snapshot before focus event.
- [x] Polite metadata and the bounded, nonblocking Surface-to-session output
      transport are implemented with echo suppression and explicit omission.
- [x] Terminal accessibility lifecycle has one deep module and old duplicate
      ownership is deleted.
- [x] System-to-Dark host repaint path is implemented.
- [x] Settings HWND/native-control explicit-Dark path is implemented.
- [x] High Contrast reset/system-color policy is implemented.
- [x] Preview discard follows the same restoration path and preserves persisted
      config bytes.
- [x] Post-redesign targeted/unit/provider filters, unified executable build,
      and full Zig suite pass on the final tree.
- [x] Final automated live accessibility/theme/High-Contrast/scaling/idle
      harness passes after the verifier and production follow-up; no broader
      composite-suite result is claimed.
- [x] Independent source implementation and semantic/deslop audits pass after
      the production input/transport follow-up.
- [x] Existing flagship verification contracts pass on the source-confirmed
      closure.
- [x] Final semantic-interest verification-contract refresh passes.
- [ ] Human Narrator and NVDA acceptance cells pass.

## Completion ledger

- Targeted Zig filters for terminal-output transport/session,
  `TerminalProvider`, and `win32_settings` pass on the current tree.
- The semantic-output redesign is source-complete. `StreamHandler` records only
  successfully committed, charset-mapped print/REP/CR/LF/tab output; hidden
  status-display output is excluded. Same-batch RIS discards its erased prefix
  and emits an ordered silent continuity reset, and interest epochs reject
  stale pre-disable batches.
- The duplicate Win32 VT/control re-parser and raw Termio forwarding are
  deleted. Focused semantic-output, transport, and announcement filters plus
  formatting and scoped diff checks pass.
- Attached, focused panes with an acquired provider keep bounded semantic
  capture interested independently of listener activity, closing the
  false-to-true listener first-output gap; UIA event emission remains
  listener-gated.
- Independent source implementation and semantic/deslop closure audits are
  clean. Existing flagship verification contracts and the final
  semantic-interest contract refresh pass.
- Final-tree `scripts/dev-windows.cmd zig build -Demit-exe=true`: PASS.
- Final-tree `scripts/dev-windows.cmd zig build test
  -Demit-test-exe=true`: PASS.
- Real Win32 message-loop coverage passes five exact key-input scenarios:
  classic `A`, classic Space, BMP Unicode, supplementary Unicode, and a
  256-unit Unicode burst. Per-scenario sandbox/artifact names are unique;
  the pure Zig test independently proves a 256-authorization deferred backlog.
- Cursor-blink reset deadlines now ceil nanosecond remainders to milliseconds,
  layered on the existing lifecycle rule that an active libxev completion is
  never canceled or reset; its callback owns logical rearming.
- The UIA selection contract is clean: terminal mutation support reports
  `None`, legacy `GetSelection` still exposes one degenerate compatibility
  caret, and `Select`/`AddToSelection`/`RemoveFromSelection` fail with the
  expected invalid-operation contract.
- Native C0 delivery for CR, LF, Tab, Backspace, and Escape is proven.
  Alt+numpad experiments were fully reverted and remain a human/native residual
  rather than an automated pass claim.
- PowerShell 7 and Windows PowerShell 5.1 parse the accessibility harness and
  flagship contract script; `Test-VerificationContracts.ps1` reports
  `flagship verification contracts: PASS (2 scenarios)`.
- The earlier full-suite pass was reconfirmed by the final-tree run above.
- Final-tree full accessibility validation with `-ResetState -TimeoutSeconds
  20 -IdleSoakSeconds 60`: PASS. Evidence:
  `.sandbox/win11/github-noctty-accessibility-6d522bd7417b/accessibility/logs/uia-tree.json`
  (`outcome=pass`, 119.962 seconds). It proves UIA notification/TextPattern
  behavior, inactive-pane silence, and a 60-second idle soak with zero
  TextChanged events or handle/thread/private-byte growth.
- The final High Contrast proof completed an exact compound SPI, host HWND/DWM,
  and Settings HWND/UIA/DWM restore with `DWMSBT_NONE=1`. The retained
  diagnostic is
  `high-contrast-restore-diagnostic.json`; the temporary recovery snapshot was
  deleted after verified restoration.
- Dark theme persistence is proven across Save, process exit, and a fresh
  relaunch: Settings index `3`, exact dark host/Settings pixels, immersive-dark
  DWM `1`, and host/Settings backdrop `1`, followed by exact sandbox-config
  restoration.
- Final cleanup restored High Contrast off and DPI 96 and left zero unexpected
  noctty processes.
- Pending: PR/review/merge/release gates and human Narrator/NVDA acceptance.

## Residual risks

- Narrator’s exact legacy-caret heuristic is not a documented guarantee; human
  retest remains mandatory.
- Native dark theming varies by Windows build; the supported Windows 11 matrix
  still requires human validation of titlebar, combos, edit fields, disabled
  controls, and focus.
- Session ownership remains concurrency-sensitive despite clean automated
  lock-order, provider-lifetime, and timer-lifecycle coverage.
- Alt+numpad behavior remains a human/native compatibility residual; no
  reverted experiment is counted as passing evidence.
- Speech-output automation is not a substitute for a human screen-reader pass.
