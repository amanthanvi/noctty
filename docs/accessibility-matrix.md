# Screen-reader compatibility matrix

What each part of the noctty window is supposed to announce, what the
automated UI Automation harness proves about it, and what has actually
been heard through a screen reader.

The three screen-reader columns record measured speech, not intent. A
cell only says `pass` when someone ran that reader against the release
build and heard the expected announcement. Everything else is
`not yet measured`, which means exactly that: the underlying UIA
semantics may be correct and asserted by the harness, but nobody has
confirmed how the reader speaks them.

`docs/accessibility-inventory.md` describes the provider architecture.
This file is the per-release record. The trust page cites it as the
accessibility claim — link to this file rather than restating results,
so a stale claim cannot outlive the record.

## Current record

- Release: unreleased (`main`)
- Windows build: not yet recorded
- Automated UIA harness: **not yet executed** with the current assertions
- Narrator: **not yet measured**
- NVDA: **not yet measured** (not installed on any noctty development or
  CI machine)
- JAWS: **not yet measured** (commercial licence; not installed)

The "UIA assertion" column reflects
`test/windows/interactive-win11-accessibility.ps1`, which walks the live
UIA tree on a real interactive Windows 11 desktop and asserts control
types, names, patterns, and events.

**Those assertions have never been executed against a live build.** They
were written alongside the providers and are checked into the harness,
but the interactive lane has not been run since, so the column records
what is asserted, not what has been observed. Treat every row as
unverified until the first run lands and this paragraph is replaced.

Even once it does run, it stays a machine-readable proxy for the reader
columns, not a replacement: it cannot prove that a reader speaks a name,
speaks it once, speaks it in a useful order, or does not talk over
itself.

| Widget | Expected announcement | UIA assertion | Narrator | NVDA | JAWS | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Host window | Window, current title | Asserted, not yet executed — ControlType Window | not yet measured | not yet measured | not yet measured | Name follows live title changes |
| Tab strip | "Tabs", Selection container | Asserted, not yet executed — ControlType Tab, Selection | not yet measured | not yet measured | not yet measured | Invisible sibling element spanning the strip rect; the tab buttons are not its HWND children |
| Tab | Tab label, "selected" for the active tab | Asserted, not yet executed — ControlType TabItem, SelectionItem, exactly one selected | not yet measured | not yet measured | not yet measured | Selection and name changes raise property events |
| New tab button | "New tab", invokable | Asserted, not yet executed — ControlType Button, Invoke | not yet measured | not yet measured | not yet measured | Painted glyph stays "+" |
| Tab overflow button | "More tabs", invokable | Asserted, not yet executed — ControlType Button, Invoke | not yet measured | not yet measured | not yet measured | Painted glyph stays a chevron |
| Terminal pane | Terminal text, current line, caret position | Asserted, not yet executed — TextPattern, TextPattern2, FindText, line units, bounding rectangles | not yet measured | not yet measured | not yet measured | Bounded to 500 history rows plus the live viewport |
| Terminal selection | Selected text, correct active end | Asserted, not yet executed — SupportedTextSelection Single; a degenerate range at the caret when nothing is selected | not yet measured | not yet measured | not yet measured | Rectangular selection reports its active row. A selection whose endpoints fall on blank cells is reported as the caret range instead |
| Terminal scrollbar | "Terminal scrollbar", position | Asserted, not yet executed — ControlType ScrollBar, RangeValue | not yet measured | not yet measured | not yet measured | Read-only through UIA; scroll with the keyboard or wheel |
| Docked search query | Edit, current query, caret and selection | Asserted, not yet executed — Text, Value, selection, focus events | not yet measured | not yet measured | not yet measured | |
| Search previous / next | "Previous match" / "Next match", invokable | Asserted, not yet executed — Button, Invoke | not yet measured | not yet measured | not yet measured | |
| Search regex / case / whole word | Name plus pressed state | Asserted, not yet executed — Button, Toggle, ToggleState tracks the flag | not yet measured | not yet measured | not yet measured | |
| Search result count | "n of m" when it changes | Asserted, not yet executed — live region, polite | not yet measured | not yet measured | not yet measured | Announcement timing is a reader behaviour and needs measurement |
| Search close | "Close search", invokable | Asserted, not yet executed — Button, Invoke | not yet measured | not yet measured | not yet measured | |
| Command palette query | Edit, current query | Asserted, not yet executed — Text, Value, selection, focus events | not yet measured | not yet measured | not yet measured | |
| Command palette list | List identity, one selected row | Asserted, not yet executed — List, Selection, SelectionItem, selected-event sender | not yet measured | not yet measured | not yet measured | |
| Host banner | Banner text when it appears or changes | Asserted, not yet executed — live region | not yet measured | not yet measured | not yet measured | |
| Settings sections | Section name, selected state | Asserted, not yet executed — RadioButton, SelectionItem, Selection | not yet measured | not yet measured | not yet measured | |
| Settings controls | Name, role, value | Partial, not yet executed — one Value edit, several Invoke buttons, visible name and control-type inventory | not yet measured | not yet measured | not yet measured | Generic Toggle and ExpandCollapse coverage is not asserted yet |

## Not covered by any provider yet

These surfaces have no custom provider and rely on whatever Windows
infers. Treat them as unvalidated:

- Custom-painted caption buttons when the integrated titlebar is on.
- Profile picker and tab-overview overlay rows (they announce as a
  changing edit and label, not as a navigable list).
- Context menus, WinRT toasts, and the tab drag preview.
- Quick terminal chrome.

Keyboard reachability is a separate gap: there is no focus-region cycle,
so chrome such as the tab strip cannot currently be reached from the
terminal with the keyboard alone.

## How we test

Automated. Intended to run on every pull request and release candidate;
as of this record it has not yet been executed with the assertions above:

```powershell
pwsh -NoProfile -File .\test\windows\interactive-win11-accessibility.ps1
```

It needs a real interactive desktop session — it drives the live UIA
tree, so it cannot run on a headless or service-session runner.

Manual, per release, for each of Narrator, NVDA, and JAWS:

1. Install the release build and note the Windows build number.
2. Start the reader, then start noctty. Do not start noctty first — some
   readers only hook windows created after they load.
3. Walk every row of the matrix above. For each one, record what the
   reader actually said, verbatim, not what you expected.
4. Repeat the walk at 100%, 200%, and 300% display scaling, with High
   Contrast off and on.
5. Capture the speech. Narrator can log its own speech history
   (Narrator key + Alt + F for the last phrase; the full history is in
   Narrator settings). NVDA has a speech viewer under Tools. JAWS has a
   speech history window. If a capture path is unavailable, transcribe
   by hand and say so in the notes.
6. Record `pass` only for cells you heard. Anything skipped stays
   `not yet measured`.

NVDA and JAWS are not installed on any noctty development or CI machine,
and installing them is a deliberate decision for the machine's owner,
not something the project does automatically. Until someone runs the
procedure above on a machine that has them, those columns stay
`not yet measured`. That is the honest state, and it is preferable to
inferring speech from the UIA tree.

## Per-release update rule

Every release updates this file:

1. Re-run the automated harness against the exact release commit.
2. Run the manual procedure with whichever readers are available.
3. Replace the "Current record" block with the release version, the
   Windows build, and the per-reader result.
4. Move the previous record into the history table below.
5. A reader that was not run is recorded as `not yet measured` for that
   release. Never carry a previous release's `pass` forward.

Optional signed evidence for a release can be recorded as
`docs/accessibility-evidence/v<version>.json` and validated with
`scripts/check-accessibility-evidence.ps1`. That schema currently
requires a `pass` in all twelve Narrator and NVDA cells, so it can only
be produced once NVDA is available on the test machine.

## History

| Release | Narrator | NVDA | JAWS | Evidence |
| --- | --- | --- | --- | --- |
| (none yet) | | | | |
