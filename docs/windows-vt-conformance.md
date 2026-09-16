# Windows VT Conformance

`+vt-probe` is a deterministic capability inventory. It distinguishes shared
parser/core support from behavior that has also been validated through the
Win32 runtime.

Its first line is `probe=static`. It never opens a PTY, so neither it nor
`test/windows/vt-probe-win32-conformance.ps1` measures the ConPTY byte stream.
The validator checks inventory metadata and referenced runtime harnesses; it is
not a bundled-versus-in-box transport baseline.

Each capability line includes:

- `category`: protocol family (`terminfo`, `osc`, `csi`, or `graphics`).
- `direction`: whether noctty advertises, parses, or parses and emits it.
- `win32-runtime`: Win32 validation status.
- `evidence`: harness or test family behind the status.

`win32-runtime` values:

- `validated`: an interactive Win32 harness exercises the protocol behavior.
- `parser-only`: parser/core support is known, but no Win32 GUI behavior is
  validated.
- `pending`: practical Win32 runtime coverage is still missing.
- `not-applicable`: the claim is not a runtime protocol behavior.

Current practical Win32 coverage:

- OSC 9 desktop notification and OSC 133 command-finish state:
  `test/windows/interactive-win11-command-finish.ps1`
- OSC 9;4 taskbar progress:
  `test/windows/interactive-win11-progress.ps1`

Run the fast metadata validator:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\test\windows\vt-probe-win32-conformance.ps1 -ResetState -TimeoutSeconds 10
```

Run the metadata validator plus the referenced Win32 runtime harnesses:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\test\windows\vt-probe-win32-conformance.ps1 -ResetState -Runtime
```

Known runtime gaps are intentionally visible in `+vt-probe`. These do not yet
have dedicated Win32 GUI harnesses:

- OSC 7 cwd state
- OSC 8 link interaction
- OSC 52 clipboard prompts, reads, and writes
- Color rendering for OSC 4 / 10 / 11 / 21
- CSI ?2026 synchronized output repaint cadence
- Kitty graphics pixel validation

## ConPTY transport generations and mangling catalog

The generation boundary is
[microsoft/terminal#17510](https://github.com/microsoft/terminal/pull/17510):

- **ConPTY v1** (Windows Terminal 1.21 and earlier, plus every in-box conhost
  verified for this work) parses child VT into a conhost text buffer and
  re-renders a snapshot to the terminal pipe. Unknown or incompletely modelled
  sequences can be dropped, reordered, or synthesized differently.
- **ConPTY v2** (Windows Terminal 1.22+ and the redistributable) parses for
  console state while separately writing the original VT bytes to the pipe.
  The 1.22 release notes describe the rewrite and its direct VT forwarding.
  [Release notes](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-22-release/)

The packaged noctty pair is v2. The first Windows build whose _in-box_ conhost
contains v2 could not be verified; do not infer the generation from the OS
build number. Use `noctty +version` or the diagnostic-bundle manifest to see
which source noctty selected.

The redistributable covers only consoles noctty hosts itself. A nested console
launched through another host—for example, `cmd.exe` from inside a WSL
shell—is redirected to the in-box conhost in System32, so bundling does not
eliminate ConPTY mangling universally.

Microsoft has not formally declared the NuGet package supported for third-party
use; [“Productize the ConPTY nuget package (for 3p use)”](https://github.com/microsoft/terminal/issues/15065)
remains open. What is verifiable is that this is a first-party,
verified-prefix, MIT-licensed, signed package shipped with each Windows
Terminal release.

### Measured child-to-master differential

Measurement host: Windows `10.0.26200.0`; in-box
`System32\conhost.exe` FileVersion `10.0.26100.1`; bundled
`conpty.dll` FileVersion `1.24.2607.10001`, ProductVersion
`1.24.260710001`.

The opt-in test in `src/pty.zig` opens `Pty`, attaches a child through
`Command.pseudo_console`, explicitly enables
`ENABLE_VIRTUAL_TERMINAL_PROCESSING` in that child, writes fixed marker and
payload bytes with `WriteFile`, and reads `Pty.out_pipe`. It runs from the
installed `zig-out/bin/ghostty-test.exe` so the bundled pair is actually
side-by-side with the test process. The printable markers survived under both
sources, proving that the in-box empty slices below are sequence stripping,
not an empty pipe or failed child.

| Sequence           | Child bytes (hex)                                                              | Bundled v2 bytes between markers | In-box v1 bytes between markers | Verdict                                            |
| ------------------ | ------------------------------------------------------------------------------ | -------------------------------- | ------------------------------- | -------------------------------------------------- |
| Kitty graphics APC | `1b5f47663d32342c733d342c763d312c613d543b546b39445646525a53306c5556466b681b5c` | same                             | empty                           | Bundled byte-exact; in-box dropped the entire APC. |
| Sixel DCS          | `1b50714e4f43545459534958454c7e1b5c`                                           | same                             | empty                           | Bundled byte-exact; in-box dropped the entire DCS. |

The bundled outer stream prepended
`1b5b31741b5b631b5b3f31303034681b5b3f3930303168` before the first marker;
neither measured payload slice was altered. The in-box stream instead
re-rendered the three markers adjacent to one another inside a synthesized
clear/home/title/cursor-update stream. This measurement establishes transport
survival only; it does not close the Kitty pixel-rendering gap listed above.

### Measured repaint-shape differential for full-screen multiplexers

Stripping whole sequences is not the only way v1 differs. Because v1 re-renders
its own text buffer instead of forwarding the child's bytes, it also rewrites
the _shape_ of a repaint. Measured by recording the master side of a pseudo
console running `herdr` 0.8.2 (a terminal multiplexer whose panes hosted an
Ink-style agent UI) at 160x45 for the same scripted 30 s scenario, once per
source:

| Emitted by the pseudo console | Bundled v2 | In-box v1 |
| ----------------------------- | ---------- | --------- |
| CUP (`CSI r;c H`)             | 22803      | 6988      |
| CUF (`CSI n C`)               | 0          | 15138     |
| ECH (`CSI n X`)               | 0          | 1933      |
| EL (`CSI n K`)                | 0          | 45        |
| CR / LF                       | 0 / 0      | 48 / 229  |
| Total bytes                   | 421084     | 302644    |

The bundled numbers are the multiplexer's own repaint, forwarded. A control run
confirms which stream is whose: a child that writes
`ESC[?1049h` `MARK_A\r\nMARK_B\r\n` `ESC[5;10H` `MARK_C   MARK_D`
`ESC[1;1H` `ESC[38;2;1;2;3m` `MARK_E` `ESC[m` `ESC[7;1H` `MARK_F` `ESC[3C`
`MARK_G` came back byte-for-byte under the bundled source, between an added
`ESC[1t ESC[c ESC[?1004h ESC[?9001h` prologue and a `ESC[?1004l ESC[?9001l`
epilogue. The same child under the in-box source came back as a synthesized
top-to-bottom redraw -- clear, then each row emitted with `ESC[K` and `CR/LF`,
`MARK_A` gone because `MARK_E` had overwritten it, and the child's own `ESC[3C`
replaced by literal spaces. So a bundled capture shows what the application
emitted; an in-box capture shows only what conhost decided to emit. In
particular the zero CR/LF count above is herdr's, not the transport's.

Neither shape rewrites every cell -- both skip runs they believe are unchanged,
and the application's own repaint skips the gaps between words
(`ESC[4;28H` `Name:` `ESC[4;52H` `Email` `ESC[4;58H` `Ingestion`). The
difference that matters is _how_ a skip is expressed, in two ways.

First, addressing. Every run in the application's repaint carries an absolute
CUP, so the cursor is re-anchored before each run and a disagreement about where
the previous run ended cannot propagate. v1's motion is relative and
context-dependent instead: CUF clamps at the right margin, LF scrolls at the
bottom row, CR interacts with margins, ECH interacts with pending wrap. One
context the terminal models differently from conhost desynchronizes the cursor
for the rest of that row or frame, with no absolute move to correct it.

Second, granularity. v1 skips at single-cell resolution in the middle of a word.
The in-box capture above contains literal runs such as `Modif` `ESC[1C` `ed`
and `9/1` `ESC[1C` `/2026`, where conhost believed one interior cell already
held the right glyph. A divergence there surfaces as one wrong _letter_ inside a
word, which is the shape "scrambled text" reports usually describe. An
application repaint skipping a whitespace gap cannot produce that shape.

A rigid whole-frame offset between the two models -- the terminal's grid holding
content some fixed number of rows and columns away from conhost's buffer -- is
worth suspecting at a **resize**, because that is where the two models reflow
independently and the paths differ again. Recording the same scenario with three
`ResizePseudoConsole` calls and noting the output offset at each one: on all
three, the bundled path emitted no snapshot of its own and the next bytes were
the application's own full repaint (`CSI ?2026h` `CSI 2J` `CSI 1;1H` ...) once
it saw the new size, while the in-box path emitted its own synthesized repaint
instead -- `CSI ?25l` `CSI H` and then overwriting from home with ECH for the
blanks, with no ED at all (the first, shrinking resize additionally emitted one
`CSI 8;30;120t` size report; the two later ones did not). This matches the
"Resize and reflow" row below: v2 resize emits no buffer snapshot, while a v1
resize can repaint into the pipe after reflowing its own viewport-only buffer.
A v1 repaint that overwrites from home without clearing is precisely the case
where a reflow disagreement between conhost's buffer and the terminal's grid can
leave cells behind, so ask about a window resize or a pane-divider drag before
treating such a report as a pure terminal bug.

To separate the two sides, run the same scenario twice on a current build: once
as shipped (bundled; confirm with the `ConPTY` line in `noctty +version`) and
once with `NOCTTY_CONPTY=inbox`. Reproducing only under `inbox` implicates the
in-box **path**, which is not the same as implicating the transport: the in-box
stream shape reaches terminal code the bundled stream never exercises (CUF at
the right margin, ECH against pending wrap, LF at the bottom row), so a terminal
bug in exactly that code would also be inbox-only. Capture the failing stream
and replay it through `libghostty-vt` before attributing it:

- The replayed screen shows the corruption. The terminal mishandles that stream
  shape; the divergence is in noctty, and the capture is the regression test.
- The replayed screen is correct. The core is consistent with the bytes it was
  given, so the divergence is either upstream (conhost's buffer already
  disagreed with the grid before the repaint) or in what a capture cannot hold:
  live resize and reflow ordering, and the GPU renderer. Rule those out before
  calling it transport.

Releases before 1.3.125 have no bundled pair at all, so they always take the
in-box path and always show the in-box shape.

On the measurement host below, both sources rendered the `herdr` scenario
correctly -- including across repeated live window resizes -- and their window
captures were pixel-identical, so the in-box _shape_ difference is not by itself
a defect here. Whether a given in-box conhost also mangles content is specific
to that conhost's vintage; do not infer it from the OS build number.

Measurement host: Windows `10.0.26200.0`; in-box `System32\conhost.exe`
FileVersion `10.0.26100.1`; bundled `conpty.dll` ProductVersion
`1.24.260710001`.

### Measured master-to-child key encoding differential

The input direction has its own opt-in probe in `src/pty_transport_probe.zig`
(`NOCTTY_CONPTY_KEY_INPUT_PROBE=1`). The child clears
`ENABLE_LINE_INPUT`, `ENABLE_ECHO_INPUT`, and `ENABLE_PROCESSED_INPUT`, sets
`ENABLE_VIRTUAL_TERMINAL_INPUT`, and echoes every byte it reads back as hex.
The parent writes one key encoding per case followed by a printable delimiter,
so a case that never arrives is still distinguishable from the next one. ConPTY
flushes a partial escape at the end of each write, so the lone-`ESC` case is not
held waiting for the delimiter behind it.

Measurement host: Windows `10.0.26200.0`; sources `inbox` and `bundled`
(`1.24.260710001`). Both sources produced identical results.

A Kitty CSI-u key number is the key's own codepoint, so `Esc` is 27 and
`Ctrl+[` is 91 with a Ctrl modifier; `CSI 27;5 u` is Ctrl+Esc, not Ctrl+[. The
`CSI 27;129 u` row is the plain `Esc` noctty writes while Num Lock is on, since
the Kitty modifier field carries the lock modifiers. Both that form and
`CSI 91;5 u` were captured from a real Claude Code session in issue #223.

| Case                                     | Written by the terminal (hex) | Read by the child (hex) | Verdict    |
| ---------------------------------------- | ----------------------------- | ----------------------- | ---------- |
| lone `ESC`                               | `1b`                          | `1b`                    | byte-exact |
| Kitty `CSI 27 u` (Esc)                   | `1b5b323775`                  | `1b5b323775`            | byte-exact |
| Kitty `CSI 27;129 u` (Esc with Num Lock) | `1b5b32373b31323975`          | `1b5b32373b31323975`    | byte-exact |
| Kitty `CSI 27;5 u` (Ctrl+Esc)            | `1b5b32373b3575`              | `1b5b32373b3575`        | byte-exact |
| Kitty `CSI 91;5 u` (Ctrl+[)              | `1b5b39313b3575`              | `1b5b39313b3575`        | byte-exact |
| `0x03`                                   | `03`                          | `03`                    | byte-exact |
| Kitty `CSI 99;5 u` (Ctrl+C)              | `1b5b39393b3575`              | `1b5b39393b3575`        | byte-exact |
| `TAB`                                    | `09`                          | `09`                    | byte-exact |
| Kitty `CSI 13 u` (Enter)                 | `1b5b313375`                  | `1b5b313375`            | byte-exact |
| modifyOtherKeys `27;5;27~`               | `1b5b32373b353b32377e`        | `1b5b32373b353b32377e`  | byte-exact |
| `CSI A`                                  | `1b5b41`                      | `1b5b41`                | byte-exact |

ConPTY does not understand CSI-u, and on the two sources measured here it does
not drop it either: an unrecognised sequence is flushed to the input queue
character by character and re-synthesised for the child unchanged. A
Kitty-encoded `Esc`, `Ctrl+[`, or `Ctrl+C` therefore reaches the application
exactly as noctty wrote it on this host, and any loss of those keys is above or
below this layer, not in it. Older in-box conhosts — including the Windows 10
build 19045 one in issue #223 — were not measured; do not generalise this row
to every ConPTY. The measurement also covers only a child reading the byte
stream; a child that reads `INPUT_RECORD`s through the console API sees
conhost's decoding of those same characters instead.

Every ConPTY session opens by asking the terminal for Win32 input mode
(`CSI ?9001h`, alongside `CSI ?1004h`). noctty does not implement mode 9001, so
ConPTY keeps parsing VT input; Windows Terminal answers it and receives exact
key records instead. Implementing 9001 would remove ConPTY's VT input parsing
from the path entirely, at the cost of the Kitty encoding it currently carries.

### Behavior by sequence class

| Surface                                    | ConPTY v1 byte stream                                                                                                                                                                                                                                                                                                               | ConPTY v2 byte stream                                                                                                                                                                          | Status and mitigation                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| APC / Kitty graphics                       | APC, PM, and SOS are ignored; this machine emitted zero bytes for the measured Kitty APC. [Ignore change](https://github.com/microsoft/terminal/pull/7340)                                                                                                                                                                          | Original APC bytes are copied to the master pipe; the bundled measurement was byte-exact.                                                                                                      | **Transport fixed in v2.** Bundle v2 and use a Kitty-capable consumer such as noctty. Cursor resynchronization after unknown image sequences was fixed later by [#20009](https://github.com/microsoft/terminal/pull/20009); that fix first shipped in the 1.25 train, so it is not assumed for noctty's 1.24 pin.                                                                                                                  |
| DCS / Sixel                                | Through 1.13 DCS was dropped; 1.14-1.21 forwarded only a whitelist. This machine emitted zero bytes for the measured Sixel DCS. [v1 report](https://github.com/microsoft/terminal/issues/17313)                                                                                                                                     | Original DCS bytes are copied; the bundled measurement was byte-exact.                                                                                                                         | **Transport fixed in v2; long-sequence resize interruption open.** The old mid-DCS SGR-reset bug was fixed by [#17194](https://github.com/microsoft/terminal/pull/17194). The current risk is CPR/DSR injection during an in-flight DCS/APC on resize, tracked by [#19621](https://github.com/microsoft/terminal/issues/19621); avoid resizing during a long transfer or retry it.                                                 |
| Synchronized output (`CSI ?2026h/l`)       | The modes could be re-emitted out of order because v1 flushed renderer snapshots asynchronously. [#15230](https://github.com/microsoft/terminal/issues/15230)                                                                                                                                                                       | The bytes are forwarded in order. ConPTY does not answer `DECRQM`; the attached terminal owns the reply.                                                                                       | **Fixed in v2.** Use DEC mode 2026 through the bundled source. The iTerm2 `DCS =1s ST` form remains **unverified**: no handler or explicit support statement was found.                                                                                                                                                                                                                                                            |
| OSC 10/11/12 colour queries                | Queries were swallowed, so the terminal could neither see nor answer them.                                                                                                                                                                                                                                                          | Queries are forwarded out and terminal replies are relayed back in. Responses larger than the old 4 KiB input buffer are preserved.                                                            | **Fixed in 1.22.** Use v2; the consumer terminal must answer. See [#17729](https://github.com/microsoft/terminal/pull/17729) and the long-response fix [#17738](https://github.com/microsoft/terminal/pull/17738). Short application escape timeouts remain an application-side reliability issue, not a ConPTY byte-stream limit.                                                                                                 |
| OSC strings and the alleged 256-byte limit | There is no 256-byte parser cap. The historical failure was fragmentation across `WriteConsole` calls; OSC fragment collection fixed it for Windows builds 19611+ / Server build 20348+. Parser-invalid C0 bytes inside an OSC can still be discarded in the v1 model. [#15551](https://github.com/microsoft/terminal/issues/15551) | The raw VT path copies the original OSC bytes and has no 256-byte limit.                                                                                                                       | **Historical fragmentation fixed by [#4870](https://github.com/microsoft/terminal/pull/4870).** The claim that the repro's number 256 came from .NET's `StreamWriter` is **inference**, not sourced fact. The documented `<255` rule for OSC 0/2 window titles is a separate acceptance rule, not a general transport cap. [Microsoft Learn](https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences) |
| Cursor shape (`DECSCUSR`)                  | Applied locally and forwarded, but shape updates once waited for a render frame.                                                                                                                                                                                                                                                    | Forwarded byte-for-byte.                                                                                                                                                                       | **Flush lag fixed by [#4896](https://github.com/microsoft/terminal/pull/4896).** Emit DECSCUSR directly. Win32 `SetConsoleCursorInfo` height is still not translated to a shape sequence ([#7382](https://github.com/microsoft/terminal/issues/7382)). Whether the v1-era tmux/nvim flicker in [#12313](https://github.com/microsoft/terminal/issues/12313) persists after v2 is **unverified**.                                   |
| OSC 8 hyperlinks                           | Re-synthesized: `id=` was rewritten, missing IDs gained a synthetic PID-based ID, non-`id` parameter keys were dropped, and BEL termination became ST.                                                                                                                                                                              | Forwarded verbatim.                                                                                                                                                                            | **Rewriting fixed in v2.** Bundle v2 when hyperlink parameter and terminator identity matter. The v1 implementation originated in [#7251](https://github.com/microsoft/terminal/pull/7251).                                                                                                                                                                                                                                        |
| OSC 52 clipboard                           | Raw writes were forwarded in pty mode; clipboard reads were deliberately not implemented.                                                                                                                                                                                                                                           | Bytes are forwarded and conhost may also execute writes, subject to version, focus, and `compatibility.allowOSC52` policy. Clipboard queries remain unsupported by design.                     | **Write transport works; read/query is inherent policy.** Treat OSC 52 writes as policy-gated and do not depend on query replies. [#5823 security rationale](https://github.com/microsoft/terminal/pull/5823)                                                                                                                                                                                                                      |
| Resize and reflow                          | `ResizePseudoConsole` reflowed conhost's viewport-only buffer and repainted it into the pipe, overwriting or desynchronizing consumer scrollback. The undocumented resize-quirk flag suppressed part of this behavior. [#16911](https://github.com/microsoft/terminal/issues/16911)                                                 | Resize itself emits no buffer snapshot and the old quirk flag is gone. ConPTY still cannot reflow scrollback it does not own, and cursor-resync traffic can conflict with an in-flight string. | **v1 repaint removed; broader desync inherent/open.** The terminal consumer owns scrollback and reflow. Avoid resize during long DCS/APC transfers. Track [#15976](https://github.com/microsoft/terminal/issues/15976) and [#19621](https://github.com/microsoft/terminal/issues/19621).                                                                                                                                           |

### Two modifications that v2 still applies

These are the two modifications in the v2 `WriteCharsVT` path; “passthrough”
does not mean every possible byte is invariant:

1. **LF to CRLF:** when `DISABLE_NEWLINE_AUTO_RETURN` is clear, bare LF is
   expanded without parsing. This can modify a raw-binary DCS payload containing
   LF. Base64 Kitty payloads do not contain LF. Mitigation: enable
   `DISABLE_NEWLINE_AUTO_RETURN` or use an encoding that excludes LF.
2. **Mode re-injection:** RIS injects both `CSI ?1004h` and `CSI ?9001h`.
   Setting or resetting focus-event mode injects only `CSI ?1004h`; the
   Win32-input-mode branch updates state and returns without injecting. This is
   inherent to conhost's host-state contract.

Both behaviors are visible in the source change and caveats for
[#17510](https://github.com/microsoft/terminal/pull/17510).

The raw-copy guarantee also requires the child output handle to have both
`ENABLE_VIRTUAL_TERMINAL_PROCESSING` and `ENABLE_PROCESSED_OUTPUT`. If either
flag is clear, v2 takes the legacy text path, where ESC and other controls are
replaced with spaces; Win32 Console API calls are synthesized as VT; and
full-buffer re-rendering is UCS-2/lossy. Those paths are outside the byte-exact
measurement above.

### Explicit residuals

- **Unverified:** the first in-box Windows build containing v2. Require the
  ConPTY shipped with Windows Terminal 1.22+ or the redistributable instead of
  naming an OS build.
- **Unverified:** there is no APC-specific passthrough PR; APC survival follows
  from the v2 whole-stream copy.
- **Inference:** .NET's 256-character `StreamWriter` buffer likely explains the
  number in one old OSC repro; the sourced cause is `WriteConsole`
  fragmentation.
- **Unverified:** whether tmux/nvim cursor flicker from #12313 reproduces after
  v2.
- **Unverified:** support policy for iTerm2's `DCS =1s ST` synchronized-update
  form.
