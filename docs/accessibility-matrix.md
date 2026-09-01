# Screen-reader compatibility matrix

What each part of the noctty window is supposed to announce, what the
automated UI Automation harness proves about it, and what has actually
been heard through a screen reader.

The three screen-reader columns record measured speech, not intent. `pass`,
`partial`, and `fail` are measured results for the exact build named in the
current record; `not yet measured` means no reader measurement exists. A
release record must use the exact release build, while the current unreleased
record labels its Debug pre-release evidence explicitly.

`docs/accessibility-inventory.md` describes the provider architecture.
This file is the per-release record. The trust page cites it as the
accessibility claim — link to this file rather than restating results,
so a stale claim cannot outlive the record.

## Current record

- Release: unreleased, branch `issues/145-accessibility-uia`
- Windows build: 10.0.26200.9168 (Windows 11 25H2)
- Automated UIA harness: **executed and passing** at `4cb829ad` — two
  consecutive runs against a reused sandbox that still held the old
  three-pane session state
- Narrator: **not yet measured**
- NVDA: **measured** — NVDA 2026.1.1, portable copy, 150% scale, High
  Contrast off, Debug build, measured at `7540fe0d`. Mixed results; see
  the NVDA column. Every accessibility product change after that measured
  commit remains unmeasured through NVDA. The NVDA column records only what
  was heard at `7540fe0d` until the current product code is rerun.
- JAWS: **not yet measured** (commercial licence; not installed)

The "UIA assertion" column reflects
`test/windows/interactive-win11-accessibility.ps1`, which walks the live
UIA tree on a real interactive Windows 11 desktop and asserts control
types, names, patterns, and events.

**Those assertions have now been executed against a live build**, on an
interactive Windows 11 desktop, and they pass. The first live run exposed
two defects in the harness itself. Both are now fixed, and the record of
them belongs here:

- The harness was **not idempotent**. It left a saved three-pane session
  behind in its sandbox, so every subsequent run without `-ResetState`
  failed at `inactive-output tab B creation`: session restore made the
  terminal-child count four where the assertion required two. The product
  was doing the right thing — the harness was counting a window it had not
  built. It now writes `window-save-state = never` into its own sandbox
  config, which gates restore as well as save, and deletes any
  `session-state.json` an older revision left behind. Two consecutive runs
  against a sandbox still holding the old three-pane state both pass.
- The harness did **not** cover the docked search's Previous / Next /
  Close buttons, although the rows below claimed it asserted them. It now
  drives all three through UIA Invoke; see those rows for what each one
  proves.

Timeouts that turn on the shape of the window now name the expected and
observed terminal-child counts and list the pane HWNDs, instead of only
naming the condition that timed out.

Even though it now runs, it stays a machine-readable proxy for the reader
columns, not a replacement: it cannot prove that a reader speaks a name,
speaks it once, speaks it in a useful order, or does not talk over
itself. The NVDA pass below demonstrates exactly that gap — the UIA tree
is correct for the tab items and chrome buttons and NVDA still does not
speak it.

### What the NVDA pass found, in one paragraph

NVDA speaks several noctty UIA providers on **custom** window classes
(`noctty.win32`, `noctty.win32.scrollbar`) and on `Static`, but ignores them
for the standard Win32 **`Button`** and **`Edit`** classes, where it falls
back to the MSAA/window-text implementation. The custom
`noctty.win32.palette_list` is the exception: NVDA speaks its row label but
not the list role, selected state, or position. So the
tab items announce as `button` with the selected tab distinguished only by
a literal `*` in the label, the new-tab and overflow buttons announce as
their painted glyphs `+` and a chevron, the three search flags lose their
pressed state, and the docked search query edit announces with no name at
all — while the UIA tree correctly reports `TabItem` + `SelectionItem`,
`New tab`, `More tabs`, `Regular expression` and `Search query`.

| Widget | Expected announcement | UIA assertion | Narrator | NVDA | JAWS | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Host window | Window, current title | Executed, passes — ControlType Window | not yet measured | pass — `[2/2] C:\WINDOWS\system32\cmd.exe`, `window` | not yet measured | Name follows live title changes. Tab position reaches the user only through this title |
| Tab strip | "Tabs", Selection container | Executed, passes — ControlType Tab, Selection | not yet measured | pass — `Tabs`, `tab control` | not yet measured | Invisible sibling element spanning the strip rect; the tab buttons are not its HWND children |
| Tab | Tab label, "selected" for the active tab | Executed, passes — ControlType TabItem, SelectionItem, exactly one selected | not yet measured | **fail** — spoken as `1: C:\WINDOWS\system32\c...`, **`button`**, never `tab`; the active tab is distinguished only by a literal `*` in the label, not by a spoken selected state | not yet measured | The UIA tree is correct (TabItem + SelectionItem). NVDA reads the underlying `Button`-class HWND instead. Ctrl+PageUp / Ctrl+PageDown announce only the terminal — no tab, no selection, no "n of m" |
| New tab button | "New tab", invokable | Executed, passes — ControlType Button, Invoke | not yet measured | **partial** — role `button` correct, name spoken as the painted glyph `+` instead of `New tab` | not yet measured | UIA name is `New tab`; the `Button` HWND's window text is `+`, and that is what NVDA speaks |
| Tab overflow button | "More tabs", invokable | Executed, passes — ControlType Button, Invoke | not yet measured | **partial** — role `button` correct, name spoken as the painted chevron glyph (unreadable) instead of `More tabs` | not yet measured | Same window-text cause as the new tab button |
| Terminal pane | Terminal text, current line, caret position | Executed, passes — TextPattern, TextPattern2, FindText, line units, bounding rectangles | not yet measured | **partial** — `Terminal: <title>`, `text`, `focused`, `Read-only terminal text`; text and command output are read as they arrive and the caret line stays truthful while scrolled back, but output and the following prompt are spoken as one run-together utterance and the review cursor does not follow the scrolled-back viewport | not yet measured | Bounded to up to 500 history rows within a 40,000-cell budget, plus one viewport. The window follows the viewport, so scrolling farther back than the budget drops the active screen from the snapshot and reports the caret at the document end. Bulk output collapses into one utterance plus repeated `terminal output omitted` throttle messages |
| Terminal selection | Selected text, correct active end | Executed, passes — GetSelection returns the real selection or a degenerate caret range; SupportedTextSelection is None because UIA cannot mutate the PTY-owned selection | not yet measured | not yet measured | not yet measured | Rectangular selection reports its active row. Endpoints on formatter-omitted trailing blank cells clamp to the nearest emitted text boundary |
| Terminal scrollbar | "Terminal scrollbar", position | Executed, passes — ControlType ScrollBar, RangeValue | not yet measured | pass — `Terminal scrollbar`, `scroll bar`, `5095` | not yet measured | Read-only through UIA; scroll with the keyboard or wheel. The element exists only once a scrollback range exists — an object-navigation sweep taken before any sustained output does not list it at all |
| Docked search query | Edit, current query, caret and selection | Executed, passes — Text, Value, selection, focus events | not yet measured | **fail** — announced as `edit`, `blank` with **no name**; the UIA name `Search query` is never spoken. Typed characters and the value are read back correctly | not yet measured | The `Edit`-class HWND has empty window text, so the MSAA fallback yields no name |
| Search previous / next | "Previous match" / "Next match", invokable | Executed, passes — ControlType Button, Invoke; invoking Next selects one of the n matches and invoking Previous moves off it, both reported as `n/m` | not yet measured | **partial** — reachable, role `button` correct, spoken as `Prev match` / `Next match` (window text) rather than the UIA names `Previous match` / `Next match` | not yet measured | Reachable only by object navigation; there is no keyboard focus path |
| Search regex / case / whole word | Name plus pressed state | Executed, passes — Button, Toggle, ToggleState tracks the flag | not yet measured | **fail** — spoken as `Regex` / `Case sensitive` / `Whole word`, `button`, with **no pressed or not-pressed state**. NVDA does speak toggle state where it is exposed — it said `Start, toggle button, not pressed` for the Windows taskbar in the same session | not yet measured | `Regex` is the window text; the UIA name is `Regular expression` |
| Search result count | "n of m" when it changes | Executed, passes — live region, polite | not yet measured | pass — announced without focus moving: `Searching`, then `2`, then `2/2` on Enter | not yet measured | Spoken as `2/2`, not the documented "n of m". Timing was prompt and did not talk over the typed characters |
| Search close | "Close search", invokable | Executed, passes — ControlType Button, Invoke; invoking it hides the docked search and returns focus to the terminal | not yet measured | pass — `Close search`, `button` | not yet measured | |
| Command palette query | Edit, current query | Executed, passes — Text, Value, selection, focus events | not yet measured | **partial** — `Command`, `edit`, `blank`; not the documented `Command palette query` | not yet measured | Typed characters are echoed correctly |
| Command palette list | List identity, one selected row | Executed, passes — List, Selection, SelectionItem, selected-event sender | not yet measured | **fail** — moving the selection speaks only the row label (`Accessibility`); no list role, no selected state and no position, although the UIA name of the selected row is `2 of 256: ...` | not yet measured | |
| Host banner | Banner text when it appears or changes | Executed, passes — live region | not yet measured | pass — invoking Undo on a fresh instance spoke `Nothing to undo.` immediately, as a live region rather than a focus change | not yet measured | The banner element persists in the tree afterwards and is reachable by object navigation |
| Settings sections | Section name, selected state | Executed, passes — RadioButton, SelectionItem, Selection | not yet measured | not yet measured | not yet measured | |
| Settings controls | Name, role, value | Partial, executed — one Value edit, several Invoke buttons, visible name and control-type inventory | not yet measured | not yet measured | not yet measured | Generic Toggle and ExpandCollapse coverage is not asserted yet |

Two measured behaviours that do not belong to a single row:

- **Viewport motion produces no spurious announcements.** Twelve
  Shift+PageUp / Shift+PageDown moves with no new output, across two
  passes, produced zero NVDA utterances, as did a 30-second focused idle
  window. This matches the harness's idle-soak assertion of zero
  TextChanged events.
- **Dismissing a transient overlay re-reads the whole terminal.** Closing
  the docked search with Escape, and completing a command-palette action,
  both made NVDA read the entire terminal document back rather than
  announcing only the restored focus. Observed twice.

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

Automated. Intended to run on every pull request and release candidate:

```powershell
pwsh -NoProfile -File .\test\windows\interactive-win11-accessibility.ps1
```

It needs a real interactive desktop session — it drives the live UIA
tree, so it cannot run on a headless or service-session runner.

`-ResetState` wipes the sandbox before the run. It is no longer required —
the harness pins `window-save-state = never` in its own sandbox config —
but it remains the quickest way to rule the sandbox out when a run fails.

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

The NVDA column in the current record was produced that way, with the
machine owner's explicit authorisation, using a **portable** NVDA copy
that was deleted afterwards:

```powershell
# Create a portable copy; no installer, no service, no registry writes.
.\nvda_<version>.exe --portable-path=<dir> --create-portable-silent
# Mute it: pick the `silence` synthesizer in <dir>\userConfig\nvda.ini,
# and capture speech from NVDA's own log instead of the Speech Viewer.
.\nvda.exe --minimal --disable-addons --log-level=12 --log-file=<log>
```

Log level 12 is NVDA's `IO` level, which records every utterance as an
`IO - speech.speech.speak` entry containing the verbatim string. That is
a diffable transcript, so a later release can be compared against this
one rather than re-described. Deviations from the procedure above in the
recorded pass — a Debug rather than release build, 150% scale only, High
Contrast off only, Narrator and JAWS not run — are stated in the current
record and must not be quietly upgraded to `pass`.

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
`scripts/check-accessibility-evidence.ps1`. That schema requires a `pass`
in all twelve Narrator and NVDA cells.

**No evidence JSON was written for the NVDA pass recorded above, and that
is correct.** Three independent reasons, any one of which is sufficient:

1. Several NVDA cells genuinely fail — the tab items, the search flag
   toggles, the docked search query edit and the command palette list.
   The schema's `status` is `{ "const": "pass" }`, so writing the file
   would mean asserting results that were not observed.
2. Narrator was not run at all, and the schema requires six Narrator
   cells.
3. Only the 150% / High-Contrast-off configuration was measured; the
   schema requires 100%, 200% and 300% with High Contrast off and on.

Independently of the matrix, the checker also requires a successful
`Test` workflow run on the default branch whose head SHA equals
`tested_commit`, with a passing `Windows 11 Interactive Composite` job and
a matching runner-provenance artifact. A feature branch cannot satisfy
that, so the file is unproducible here even if every cell had passed.

## History

| Release | Narrator | NVDA | JAWS | Evidence |
| --- | --- | --- | --- | --- |
| (none yet) | | | | |

The current record is a pre-release branch measurement, not a release, so
it does not belong in this table yet. It moves here, unchanged, when the
commit it names ships.
