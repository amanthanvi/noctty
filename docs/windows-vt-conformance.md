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
