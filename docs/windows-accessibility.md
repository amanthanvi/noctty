# Windows screen-reader matrix (C34)

Last reviewed: 2026-08-19. Partial UIA is the current contract; this
page is the published matrix, not a claim of WCAG completion.

| Surface | Narrator | NVDA | JAWS | Notes |
| --- | --- | --- | --- | --- |
| Host window title (`UIA_NamePropertyId`) | Yes | Yes | Yes | Live HWND title; fallback "winghostty" |
| Terminal text (TextPattern / TextPattern2) | Partial | Partial | Partial | Read-only, bounded ranges, caret anchor |
| Command palette list | Partial | Partial | Untested | Name announces selected row; no per-row Invoke yet |
| Native settings controls | Yes | Yes | Yes | Stock HWND providers |
| Docked search edit | Yes | Yes | Yes | Native EDIT |
| Tab buttons | Partial | Partial | Untested | Owner-draw; name from tab title |
| Confirm overlay buttons | Yes | Yes | Yes | Native BUTTON focus + Enter/Esc |
| Split panes as peers | Partial | Partial | Untested | Focus follows the focused pane |
| Quick terminal | Partial | Partial | Untested | Same host UIA tree |

## Still to do

- Broader per-widget `IRawElementProviderFragment` coverage for chrome
  buttons that are still owner-draw only.
- Per-row Invoke on the palette list.
- JAWS release sign-off on a clean machine.

UIA events go through `src/apprt/win32_uia/events.zig` and no-op when
`UiaClientsAreListening()` is false.
