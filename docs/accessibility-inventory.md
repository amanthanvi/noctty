# Windows accessibility contract

winghostty uses native Win32 accessibility for standard button, list, dialog,
and settings controls. It installs custom UI Automation providers where native
semantics are incomplete, including terminal/owner-drawn surfaces and the
palette/search Edit HWNDs that need reliable Text, Text2, and Value patterns.

| Surface | Contract | Provider |
| --- | --- | --- |
| Host window and custom caption | Window name, focus, native caption buttons | winghostty root chained to host provider |
| Terminal pane | Bounded document text/ranges, visible geometry, active caret range, text/caret/focus changes | winghostty TextPattern/TextPattern2 provider |
| Universal Palette | Stable list identity, navigable result rows, one selected-result announcement, query-edit focus | winghostty selection/list-item fragments plus custom Text/Text2/Value provider on the native query Edit HWND |
| Tabs, docked search, settings, confirmation/update/recovery UI | Name, role, value/selection, keyboard focus | native HWND providers; custom Text/Text2/Value provider on the docked-search Edit HWND |

Automated acceptance is `test/windows/interactive-win11-accessibility.ps1`.
It emits exact-source/binary provenance with the UIA tree and requires terminal
text, all four directional split-focus moves,
palette selection/focus semantics, non-overlapping native settings controls,
settings owner-close survival, idle resource bounds, graceful close/reopen,
and clean Explorer/WER postflight. Pull requests run the quick interactive
lane; release candidates require the full default-branch interactive lane with
exact-SHA, hash-bound evidence. Provider unit tests cover the degenerate
TextPattern2 caret range plus its ABI and semantics. The physical screen-reader
matrix is optional manual acceptance evidence for validating that contract end
to end. When recording it, verify the exact build with Narrator and NVDA:
navigate tabs and panes, read terminal text, open/filter/invoke the palette,
edit settings, and dismiss confirmation/update surfaces at 100%, 200%, and
300% DPI with High Contrast both off and on.

Stable release preflight does not require a manual matrix attestation.
Optional reports live at `docs/accessibility-evidence/v<version>.json`; the
validator binds a report to an ancestor commit and rejects later code changes.
See `docs/accessibility-evidence/README.md`.

Custom row fragments exist only for the owner-drawn Universal Palette list.
Standard native lists keep their HWND providers so Windows owns their roles,
navigation, selection patterns, focus, and events.
