# Windows accessibility contract

winghostty uses native Win32 accessibility for standard edit, button, list,
dialog, and settings controls. Custom UI Automation providers are limited to
owner-drawn surfaces whose semantics Win32 cannot infer.

| Surface | Contract | Provider |
| --- | --- | --- |
| Host window and custom caption | Window name, focus, native caption buttons | winghostty root chained to host provider |
| Terminal pane | Bounded document text/ranges, visible geometry, active caret range, text/caret/focus changes | winghostty TextPattern/TextPattern2 provider |
| Universal Palette | Stable list identity, navigable result rows, one selected-result announcement, query-edit focus | winghostty selection/list-item fragment providers; native edit for query |
| Tabs, search, settings, confirmation/update/recovery UI | Name, role, value/selection, keyboard focus | native HWND providers |

Automated acceptance is `test/windows/interactive-win11-accessibility.ps1`.
It emits exact-source/binary provenance with the UIA tree and requires terminal
text plus a degenerate TextPattern insertion range, all four directional split-focus moves,
palette selection/focus semantics, non-overlapping native settings controls,
settings owner-close survival, idle resource bounds, graceful close/reopen,
and clean Explorer/WER postflight. Pull requests run the quick interactive
lane; release candidates require the full workflow-dispatch lane. Before a
public release, provider unit tests cover TextPattern2 caret ABI/semantics and
the physical screen-reader matrix validates that contract end to end. Manually
verify the exact build with Narrator and NVDA:
navigate tabs and panes, read terminal text, open/filter/invoke the palette,
edit settings, and dismiss confirmation/update surfaces at 100%, 200%, and
300% DPI with High Contrast both off and on.

Stable releases fail preflight without a durable, exact-matrix attestation in
`docs/accessibility-evidence/v<version>.json`. The validator binds the report to
an ancestor commit and rejects later code changes; see
`docs/accessibility-evidence/README.md`.

Custom row fragments exist only for the owner-drawn Universal Palette list.
Standard native lists keep their HWND providers so Windows owns their roles,
navigation, selection patterns, focus, and events.
