# Windows accessibility contract

noctty installs custom UI Automation providers wherever native Win32
semantics are wrong or missing, which is most of its chrome: the tab
strip and its buttons are owner-drawn native `BUTTON`s that would
otherwise announce as plain buttons, and the terminal is an
owner-drawn surface with no native text semantics at all. Native HWND
providers are kept and composed with wherever they already say the
right thing.

| Surface                        | Contract                                                                                                                                                                                                                                                                    | Provider                                                                                                                                                                                                                                                                                                        |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host window and custom caption | Window name following the live title                                                                                                                                                                                                                                        | noctty root chained to the host provider. The root exposes no patterns and reports itself not focusable; with the integrated titlebar on it is also a fragment root whose only children are the caption buttons                                                                                                 |
| Caption buttons                | "Minimize", "Maximize" or "Restore", "Close"; invokable; not keyboard focusable                                                                                                                                                                                             | noctty caption-button fragments of that root (Button + Invoke). They are painted inside the client area and own no HWND, so no native provider composes underneath. Bounds come from the rects the painter uses, Invoke posts the `WM_SYSCOMMAND` the mouse path sends, and the zoomed flip raises a Name event |
| Tab strip                      | Selection container named "Tabs"                                                                                                                                                                                                                                            | noctty chrome provider on an invisible, hit-transparent child spanning the strip rect. The tab buttons are siblings, not its HWND children; they link back through SelectionContainer                                                                                                                           |
| Tab                            | Tab label, selected state, program status (OSC 7501) as ItemStatus, selection, name and item status events                                                                                                                                                                  | noctty chrome provider per tab button (TabItem + SelectionItem)                                                                                                                                                                                                                                                 |
| New tab / tab overflow         | "New tab" / "More tabs", invokable                                                                                                                                                                                                                                          | noctty chrome providers (Button + Invoke); the painted glyphs are unchanged                                                                                                                                                                                                                                     |
| Terminal pane                  | Bounded document text and ranges, visible geometry, a truthful caret while the live screen remains inside the snapshot (otherwise the off-window caret is reported at the document end), real selections with an ordered active end, and text/caret/selection/focus changes | noctty TextPattern/TextPattern2 provider                                                                                                                                                                                                                                                                        |
| Terminal scrollbar             | "Terminal scrollbar" plus position over the scrollback extent                                                                                                                                                                                                               | noctty chrome provider (ScrollBar + RangeValue, read-only)                                                                                                                                                                                                                                                      |
| Docked search                  | Query edit with Text/Text2/Value; named previous/next/close buttons; regex, case, and whole-word toggles carrying their pressed state; result count as a polite live region                                                                                                 | custom Text/Text2/Value provider on the query Edit plus noctty chrome providers on the buttons and the count                                                                                                                                                                                                    |
| Universal Palette              | Stable list identity, navigable result rows, one selected-result announcement, query-edit focus                                                                                                                                                                             | noctty selection/list-item fragments plus a custom Text/Text2/Value provider on the native query Edit                                                                                                                                                                                                           |
| Confirm prompt                 | Prompt heading and body announced when the prompt opens, and reachable afterwards; named accept / cancel buttons that can be invoked                                                                                                                                        | noctty chrome providers as polite live regions on the owner-drawn title and body children, plus the overlay `SettingsControlProvider` pair on the accept / cancel buttons (Button + Invoke)                                                                                                                     |
| Host banners                   | Banner text announced when it appears or changes; named close, Open Release, Install and Dismiss buttons that can be invoked                                                                                                                                                | noctty chrome provider as a live region on the banner, plus noctty chrome providers on its buttons (Button + Invoke)                                                                                                                                                                                            |
| Settings window                | Section name/role/selection and per-control name, role, and value; whether a section has an invalid value or unsaved changes (ItemStatus), whether a field holds a value Settings will not accept, whether it differs from its default (ItemStatus, and the field's MSAA description), and a named Reset button after such a field ("Reset <field>", invokable); the status line and the close prompt as polite live regions; a named search field ("Search settings", Edit + Value, with HelpText), the header line that says how many settings a search found as a polite live region, and each section's search count in its ItemStatus; the All settings page's list ("All settings", List, HelpText with its keys) of every config key, a ListItem each, named by the key and its value in effect, its description, what Windows does with it and how to edit it as HelpText, with the keyboard focus on the selected row; and the Keybindings page's list ("Key bindings", List, HelpText with its keys) of every binding in effect, a ListItem each, named by its keys and action, the action's description and whether it is a default as HelpText, the focus on the selected row as well              | `SettingsSectionGroupProvider`, `SettingsSectionProvider`, and `SettingsControlProvider`, and for the All settings and Keybindings lists `PaletteListProvider` with its rows taking the focus (`focus_selected_row`); native providers compose underneath and are the fallback when STA cannot be confirmed                                                                                                                                 |

Terminal selection offsets are resolved against the plain-text formatter's
pin map. Because that formatter omits blank trailing cells, endpoints on
those cells clamp to the nearest emitted text boundary; the selected text
remains available without inventing spaces that are absent from the snapshot.
`GetSelection` returns a degenerate range at the insertion point only when
there is no text-bearing selected extent.

Surfaces with no provider yet: profile picker and tab-overview overlay
rows, context menus, WinRT toasts, the tab drag preview, and
quick-terminal chrome.

Keyboard reachability is a focus-region cycle: `cycle_focus_region`
(Ctrl+F6 / Ctrl+Shift+F6 by default) moves real Win32 focus between the terminal
pane, the tab strip, the docked search query, and the host banner,
skipping regions that are not on screen; Escape returns to the terminal.
The order and the skip rule live in `src/apprt/win32/focus_region.zig`
as a pure model with unit tests; `Host.focusRegionHwnd` in
`src/apprt/win32/host.zig` maps a region to the HWND that takes focus.
Real focus is the contract, because each landing HWND
raises its own UIA focus-changed event from `WM_SETFOCUS`. In the host
banner, focus lands on its first button (Open Release or Install on the
update notice, the close button on a message); the buttons are real
BUTTON children with their own providers, and the banner text stays a
live region that does not take focus. The cycle does not reach the
individual docked-search buttons, the caption buttons, or overlay rows.
The caption buttons sit in the UIA tree and are invokable, but they
declare `IsKeyboardFocusable = false`: nothing moves real Win32 focus to
them, so the tree must not say otherwise.

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
