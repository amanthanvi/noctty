# Windows accessibility contract

noctty installs custom UI Automation providers wherever native Win32
semantics are wrong or missing, which is most of its chrome: the tab
strip and its buttons are owner-drawn native `BUTTON`s that would
otherwise announce as plain buttons, and the terminal is an
owner-drawn surface with no native text semantics at all. Native HWND
providers are kept and composed with wherever they already say the
right thing.

| Surface | Contract | Provider |
| --- | --- | --- |
| Host window and custom caption | Window name following the live title | noctty root chained to the host provider. The root exposes no patterns and reports itself not focusable. Integrated-titlebar caption buttons are custom-painted and have no provider |
| Tab strip | Selection container named "Tabs" | noctty chrome provider on an invisible, hit-transparent child spanning the strip rect. The tab buttons are siblings, not its HWND children; they link back through SelectionContainer |
| Tab | Tab label, selected state, selection and name events | noctty chrome provider per tab button (TabItem + SelectionItem) |
| New tab / tab overflow | "New tab" / "More tabs", invokable | noctty chrome providers (Button + Invoke); the painted glyphs are unchanged |
| Terminal pane | Bounded document text and ranges, visible geometry, a truthful caret while the live screen remains inside the snapshot (otherwise the off-window caret is reported at the document end), real selections with an ordered active end, and text/caret/selection/focus changes | noctty TextPattern/TextPattern2 provider |
| Terminal scrollbar | "Terminal scrollbar" plus position over the scrollback extent | noctty chrome provider (ScrollBar + RangeValue, read-only) |
| Docked search | Query edit with Text/Text2/Value; named previous/next/close buttons; regex, case, and whole-word toggles carrying their pressed state; result count as a polite live region | custom Text/Text2/Value provider on the query Edit plus noctty chrome providers on the buttons and the count |
| Universal Palette | Stable list identity, navigable result rows, one selected-result announcement, query-edit focus | noctty selection/list-item fragments plus a custom Text/Text2/Value provider on the native query Edit |
| Host banners | Banner text announced when it appears or changes | noctty chrome provider as a live region |
| Settings window | Section name/role/selection and per-control name, role, and value | `SettingsSectionGroupProvider`, `SettingsSectionProvider`, and `SettingsControlProvider`; native providers compose underneath and are the fallback when STA cannot be confirmed |

Terminal selection offsets are resolved against the plain-text formatter's
pin map. Because that formatter omits blank trailing cells, endpoints on
those cells clamp to the nearest emitted text boundary; the selected text
remains available without inventing spaces that are absent from the snapshot.
`GetSelection` returns a degenerate range at the insertion point only when
there is no text-bearing selected extent.

Surfaces with no provider yet: custom-painted caption buttons, profile
picker and tab-overview overlay rows, context menus, WinRT toasts, the
tab drag preview, and quick-terminal chrome. There is no keyboard
focus-region cycle, so chrome is not reachable from the terminal with
the keyboard alone.

Automated acceptance is `test/windows/interactive-win11-accessibility.ps1`.
It emits exact-source/binary provenance with the UIA tree and requires
terminal text, all four directional split-focus moves, tab
container/item selection semantics, named chrome and search controls
with their patterns, scrollbar range, palette selection/focus
semantics, non-overlapping native settings controls, settings
owner-close survival, idle resource bounds, normal-path graceful close/reopen, and
clean Explorer/WER postflight. Pull requests run the quick interactive
lane; release candidates run the full default-branch interactive lane.
Provider unit tests cover the chrome provider patterns, the scrolled-back
caret, terminal selection with its active end, and the degenerate
TextPattern2 caret range plus its ABI and semantics. Deferred-disconnect tests
cover successful retry accounting. Failed disconnect fallbacks currently log
the failure and release the provider's creation reference, so retaining that
reference after retry exhaustion, allocation failure, or a failed queue post
is not an accepted or tested lifecycle guarantee.

The harness proves UIA structure, not speech. What each widget should
announce and which readers have actually been heard are recorded in
[accessibility-matrix.md](accessibility-matrix.md); at present only
NVDA has been measured, on a pre-release branch build, with mixed
results.

Stable release preflight does not require a manual matrix attestation;
`-RequireAccessibilityEvidence` is opt-in. Optional reports live at
`docs/accessibility-evidence/v<version>.json`; the validator binds a
report to an ancestor commit and rejects later code changes. See
`docs/accessibility-evidence/README.md`.

Custom row fragments exist only for the owner-drawn Universal Palette
list. Standard native lists keep their HWND providers so Windows owns
their roles, navigation, selection patterns, focus, and events.
