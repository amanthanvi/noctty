# Spike: durable-session feasibility (C16 / F6 process-durability aspiration)

Research date: 2026-08-19. Resolves ticket
[R13](../tickets/R13-durable-session-spike.md). Method: primary-source
research (Microsoft console docs, microsoft/terminal source and issues,
competitor docs/issues) plus local code reading (`src/pty.zig`,
`src/termio/Exec.zig`, `src/Command.zig`, `src/apprt/win32_session_*.zig`).
No experiments were run; every load-bearing external claim carries a URL.
Uncertainty is marked inline.

## Executive summary (verdict first)

**Verdict: feasible-with-broker.** ConPTY sessions die with the process
that holds the `HPCON` — there is no OS-level way to park a session and
re-open it later by name — so shells surviving a UI restart require a
separate session-host process that owns the ConPTYs and child processes,
with the UI attaching over named pipes. This is proven, shipped art on
Windows (VS Code's pty host does exactly this with ConPTY today), the
handle-handoff mechanics are demonstrated by Windows' own defterm handoff,
and winghostty's termio already treats the Windows pty as a plain pair of
pipe handles, which is precisely the shape a broker attach needs. **Cost
class: XL confirmed** for the full feature (broker lifecycle, reattach
protocol, scrollback ownership, failure modes), but the smallest testable
increment — a standalone conpty-host spike proving kill-UI/reattach — is
an M and should be built before any winghostty integration.

## 1. ConPTY lifetime findings (the load-bearing facts)

**What a pseudoconsole is.** `CreatePseudoConsole(size, hInput, hOutput,
flags, &hPC)` creates a console session hosted in a separate
conhost.exe process; the caller supplies the two pipe ends and receives
an `HPCON` ([CreatePseudoConsole](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole),
[Pseudoconsoles overview](https://learn.microsoft.com/en-us/windows/console/pseudoconsoles)).
The implementation (mirrored in microsoft/terminal's
[winconpty.cpp](https://github.com/microsoft/terminal/blob/main/src/winconpty/winconpty.cpp))
shows `HPCON` is a heap struct of three real kernel handles: `hSignal`
(control pipe for resize/close), `hPtyReference` (a ConDrv client handle
that keeps the console server alive), and `hConPtyProcess` (the conhost
process handle). Conhost is launched as
`conhost.exe --headless --signal ... --server ...` by the creating
process.

**What dies when the creating process exits.** The `HPCON`'s reference
handle is what keeps the session alive: "The HPCON handle owned by your
application keeps the pseudoconsole session alive indefinitely by
default" ([ReleasePseudoConsole remarks](https://learn.microsoft.com/en-us/windows/console/releasepseudoconsole)).
When the owning process exits or crashes, the kernel closes those
handles, which is equivalent to `ClosePseudoConsole`: conhost tears
down and "Closing a pseudoconsole will send **CTRL_CLOSE_EVENT** to each
client application that is still connected"
([ClosePseudoConsole](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole));
winconpty's own comment: client apps "behave as though the console
window they were running in was closed"
([winconpty.cpp](https://github.com/microsoft/terminal/blob/main/src/winconpty/winconpty.cpp)).
The default console ctrl handler for CTRL_CLOSE_EVENT calls
`ExitProcess`, with a ~5 s hung-app timeout before forced termination
([HandlerRoutine](https://learn.microsoft.com/en-us/windows/console/handlerroutine)).
**Net: UI-process death kills the shell and its whole console process
tree. This is the fact that makes durability impossible without an
architecture change.**

**Sessions are re-attachable while someone holds them.** A conhost
maintainer states the intended model: "Like a pty, a pseudoconsole
exists regardless of it having any attached children, and since it's
held open, you should be able to reattach any number of children to it"
([microsoft/terminal#329](https://github.com/microsoft/terminal/issues/329)).
The session outlives the *shell*; it does not outlive its *owner*.

**Handles can be handed to another process — but only hand-to-hand.**
The constituent handles are ordinary kernel handles: Windows' own
default-terminal handoff passes the in/out/signal pipes plus the
reference handle and server/client process handles over COM from conhost
to Windows Terminal
([ITerminalHandoff.idl](https://github.com/microsoft/terminal/blob/main/src/host/proxy/ITerminalHandoff.idl)),
and winconpty exposes `ConptyPackPseudoConsole` to reassemble loose
received handles into a working `HPCON` in the receiving process
([winconpty.cpp](https://github.com/microsoft/terminal/blob/main/src/winconpty/winconpty.cpp)).
So live transfer via `DuplicateHandle`/COM is proven. What does **not**
exist is any `OpenPseudoConsole`-style API to re-acquire a session
after its owner died — the public surface is only
Create/Resize/Close ([console API docs](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole))
plus, on Windows 11 24H2+, `ReleasePseudoConsole`
([docs](https://learn.microsoft.com/en-us/windows/console/releasepseudoconsole)),
which only lets the session auto-exit when the last client disconnects.
A crash of the sole handle-holder is unrecoverable. (Marked certain for
the documented API; the absence of undocumented resurrection paths is
high-confidence but technically unfalsifiable.)

**Version/behavior notes.** Pre-24H2 `ClosePseudoConsole` blocks until
all clients disconnect (deadlock hazard if the output pipe isn't
drained); 24H2 made it return immediately
([ClosePseudoConsole](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole)).
ConPTY is also redistributable: terminals can bundle their own
OpenConsole/conpty.dll pair instead of the OS one
([microsoft/terminal#1130](https://github.com/microsoft/terminal/issues/1130);
WezTerm bundles pair 1.24.x,
[wezterm#7774](https://github.com/wezterm/wezterm/issues/7774)) — a
broker could pin its ConPTY version independent of the OS.

**Durability ceiling: the logon session.** Interactive console
processes are terminated at user logoff
([HandlerRoutine, CTRL_LOGOFF_EVENT](https://learn.microsoft.com/en-us/windows/console/handlerroutine)).
Any user-mode broker gives durability *across UI restarts within a
logon session* — not across logoff/reboot. Cross-reboot durability
would need a service in session 0 hosting interactive ptys, which is
out of scope and hostile territory.

## 2. Where winghostty stands today (code reading)

- `src/pty.zig` (`WindowsPty`, `CreatePseudoConsole` at ~line 430):
  the UI process creates the pipe pair (a named pipe for input because
  libxev/IOCP needs overlapped I/O, an anonymous pipe for output), calls
  `CreatePseudoConsole`, and holds the `HPCON`. `deinit` closes
  everything including `ClosePseudoConsole`.
- `src/termio/Exec.zig`: `Subprocess.start` opens the Pty, then spawns
  the child via `src/Command.zig`, which attaches it with
  `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` (`Command.zig` ~lines 297–370).
  Crucially, on Windows termio's return value is just
  `.read = pty.out_pipe, .write = pty.in_pipe` — plain pipe HANDLEs fed
  to the read thread (`ReadThread.threadMainWindows`). The VT parser and
  `Screen` (scrollback) live in the UI process's termio thread.
- `src/apprt/win32_job_object.zig` + the `windows_job_object_plan` in
  Exec: opt-in Job Object with `KILL_ON_JOB_CLOSE` — ownership of that
  job handle determines who kills the tree; today it dies with the UI.
- `src/apprt/win32_session_state.zig` / `win32_session_persistence.zig`:
  session schema v1 is layout/cwd/profile/title only, "deliberately
  excludes terminal contents, scrollback, command lines, and other
  runtime process state" — the exact stopping point Windows Terminal
  chose (§4).

The architectural good news: because termio already consumes opaque
pipe handles, an "attach to broker session" backend is a substitution at
one seam (`Subprocess.start`), not a rewrite of the IO stack.

## 3. Architecture options compared

**A. Session-host broker (recommended).** A separate winghostty-session
process (same codebase, second exe or `--session-host` mode) owns
`Pty.open`, `Command` spawn, the Job Object, and a bounded raw-VT ring
buffer per session; the UI connects over a named pipe (per-user
namespace, DACL'd to the user), speaking a small protocol:
`list/spawn/attach/detach/resize/kill` + raw byte streams. On UI
restart, the UI reattaches, replays the ring buffer into a fresh
`Screen`, and resumes. This is exactly VS Code's shipped design: pty
host process + "process reconnection … reconnects to the previous
process and restores its content when reloading a window," with replay
bounded by `terminal.integrated.persistentSessionScrollback`
([VS Code Terminal Advanced](https://code.visualstudio.com/docs/terminal/advanced),
[vscode#117265](https://github.com/microsoft/vscode/issues/117265),
[vscode#127195](https://github.com/microsoft/vscode/issues/127195)), and
the shape Windows Terminal's own "remote attach" proposal sketches (a
"WT Server" owning the ConPTYs,
[microsoft/terminal#20077](https://github.com/microsoft/terminal/issues/20077)).
Variant worth choosing deliberately: **one host process per session**
(crash isolation, simpler updates) vs one daemon for all (cheaper,
single point of failure — VS Code's single pty host being unresponsive
is a recurring user-visible failure,
[vscode#117548](https://github.com/microsoft/vscode/issues/117548)).

**B. OS tricks without a broker — degenerate, rejected.** Handing the
handles to a surviving stub at crash time can't work (no warning on
crash); pre-duplicating handles into a stub process that does nothing
but hold them still leaves nobody draining the output pipe (child
output stalls; pre-24H2 close semantics deadlock) and nobody owning
resize/signal — the stub grows into a broker. `ConptyPackPseudoConsole`
makes adoption *possible*, but only broker-shaped processes can use it.

**C. Full mux server (WezTerm shape) — more than needed.** Server-side
terminal model with a multiplexing protocol gives perfect reattach
fidelity and remote domains, at the cost of owning a second terminal
state implementation and a much bigger protocol. WezTerm's Windows
experience shows the tax (§6). Not the v1 shape; the broker protocol
should merely not preclude evolving toward it.

**D. WSL-only durability — real but partial.** Run the persistence on
the Linux side (tmux/auto-attach, or a ghostinthewsl-style VSOCK bridge
with real Linux PTYs). Dodges ConPTY entirely and survives even
UI+broker death, but covers only WSL profiles — PowerShell/cmd users
(the benchmark winghostty user) get nothing. Reasonable as a *later*
fidelity upgrade for WSL profiles, not as the answer to F6.

### Minimal-viable sketch for winghostty (option A)

Changes:
- **New `src/session-host/`** (or a mode of the main exe): owns
  `Pty.open` + `Command.start` + Job Object; per-session bounded raw-VT
  ring buffer (spill-to-disk optional later); named-pipe control +
  data channels; session registry with stable IDs.
- **`src/termio/Exec.zig`**: `Subprocess.start` grows a second Windows
  path — instead of `Pty.open`+spawn locally, request/attach a broker
  session and return the connected pipe handles. The read thread,
  stream handler, and `Termio` are unchanged (they already consume
  HANDLEs).
- **`src/pty.zig`**: split `WindowsPty` into "create locally" (today)
  and "proxy" (resize/kill become protocol messages instead of
  `ResizePseudoConsole`/`ClosePseudoConsole`).
- **`src/apprt/win32_session_state.zig`**: schema v2 adds a broker
  session ID per leaf; restore flow tries reattach, falls back to fresh
  spawn (current behavior) when the session is gone — durability
  degrades to today's layout-only restore, never worse.
- **Stays untouched:** renderer, `Screen`/scrollback (still UI-side,
  rebuilt by replay), config, win32 chrome, all POSIX paths.

## 4. Failure-mode analysis

- **Broker crash:** every session it holds dies (kernel closes the
  HPCONs → CTRL_CLOSE_EVENT → clients terminated, §1). Mitigations:
  per-session host processes; keep the broker tiny and UI-free so its
  crash surface is small; UI shows "session lost" and respawns.
- **Broker update:** an updated UI must talk to a broker binary still
  running the old version. Requires a versioned protocol with an
  explicit policy — adopt (compatible), drain (old sessions keep old
  broker until they exit, new sessions get new broker), or migrate via
  handle handoff (`ConptyPackPseudoConsole` makes live migration
  technically possible; ship it later, if ever). Do not silently kill
  old brokers on update.
- **Elevation:** a non-elevated broker must not host elevated shells
  and vice versa; sessions cannot cross the boundary. Windows
  Terminal's answer is separate elevated windows/process trees — mirror
  it: one broker instance per integrity level, elevated sessions
  explicitly badged; v1 can scope durability to non-elevated only.
  Pipe DACLs must restrict to the owning user + integrity level.
- **Scrollback ownership during detach:** while no UI is attached,
  *someone* must drain the output pipe (otherwise child output
  backpressures; pre-24H2, close paths can deadlock —
  [ClosePseudoConsole](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole)).
  The broker's ring buffer is therefore mandatory, not an optimization.
  Replay fidelity is bounded: alt-screen TUIs won't replay perfectly
  from a byte ring (VS Code caps restored scrollback and accepts this;
  [docs](https://code.visualstudio.com/docs/terminal/advanced)); a
  resize nudge on reattach makes ConPTY repaint the live viewport,
  which is what makes TUIs usable again (behavior widely relied on;
  exact repaint guarantees undocumented — uncertain). Full fidelity =
  option C's cost.
- **Job objects / orphan control:** the `KILL_ON_JOB_CLOSE` job must be
  owned by the broker, and "close all sessions on real quit" becomes an
  explicit broker verb — otherwise durable sessions become orphan
  leaks users blame on winghostty.
- **Logoff/reboot:** not survivable by design (§1); the feature must be
  honestly scoped as "survives UI restarts and crashes," composing with
  the existing layout restore for the reboot case.

## 5. Cost class and smallest testable increment

**XL confirmed** for the graduated feature (broker lifecycle +
versioned protocol + reattach UX + elevation policy + ring
buffer/replay + update strategy + tests). It is an XL of mostly *known*
engineering, though — the OS facts are settled and the pattern is
shipped art (VS Code), not research risk.

**Smallest testable increment (M):** a standalone `conpty-host` spike —
one Zig exe reusing `pty.zig`+`Command.zig` that spawns pwsh under a
ConPTY it owns, ring-buffers output, and serves one named pipe; plus a
trivial attach client. Test: attach, run a TUI, hard-kill the client,
reattach from a new client, confirm the shell and TUI survived and the
viewport repaints after a resize nudge. That one artifact retires the
core risk (lifetime semantics, drain-while-detached, replay adequacy)
before any winghostty integration, and its protocol can be thrown away.
Second increment: swap `Subprocess.start` to attach mode behind a
config flag, sessions marked non-durable everywhere else.

## 6. What the competitors teach

**WezTerm mux.** `wezterm-mux-server` + domains is the full option-C
architecture: server-side terminal model, reattach with scrollback,
remote domains ([multiplexing docs](https://wezterm.org/multiplexing.html);
local §5 of [wezterm.md](wezterm.md)). Its Windows record is the
cautionary tale: crashes with unix domains on Windows
([#1747](https://github.com/wezterm/wezterm/issues/1747)), mux-socket
setup implicated in minute-scale Windows startup stalls
([#7782](https://github.com/wezterm/wezterm/issues/7782)), unbounded
mux PDU allocation OOM
([#7527](https://github.com/wezterm/wezterm/issues/7527)). Lesson: the
full mux buys fidelity and remoting but imports a protocol+memory
liability; winghostty should start with the thin broker and bounded
buffers, and treat mux-grade fidelity as a separate future decision.

**Wave job manager.** Wave ships durability *only* where it's easy — a
remote job manager over Unix sockets keeps SSH shells alive and buffers
output, while "Local terminals and WSL connections use standard
sessions" ([durable sessions doc](https://docs.waveterm.dev/durable-sessions);
local [wave-terminal.md](wave-terminal.md) §5) — and its users promptly
asked for local durability
([wavetermdev/waveterm#3248](https://github.com/wavetermdev/waveterm/issues/3248)).
Lesson: demand is validated, the local-ConPTY half is the unclaimed
hard part, and shipping it would leapfrog Wave on its own headline
feature.

**Contour daemon.** Contour 0.7.0's daemon mode moves sessions into a
background process with `contour client` attach — architecturally the
same broker shape, proving a single-binary terminal can grow one
without a rewrite ([README](https://github.com/contour-terminal/contour/blob/master/README.md);
local [long-tail.md](long-tail.md)). Whether daemon mode actually works
on Windows/ConPTY is undocumented (README is silent; "new … and still
settling") — uncertain, and winghostty should assume no one has proven
the ConPTY-broker terminal yet outside VS Code's embedded case: a real
first-mover slot for a native Windows terminal.

**ghostinthewsl.** Replaces ConPTY entirely for WSL with a bridge
process inside the guest speaking Hyper-V sockets/VSOCK and allocating
real Linux PTYs, plus a WSL keepalive
([repo](https://github.com/Codavo/ghostinthewsl); local
[ghostty-windows-forks.md](ghostty-windows-forks.md)). It documents no
detach/reattach today (uncertain whether sessions survive UI restart),
but the architecture is inherently broker-shaped on the Linux side:
guest-side PTY ownership would give WSL sessions durability that even
survives the Windows broker, and dodges every ConPTY limitation. Lesson:
a WSL fidelity tier can be layered on the same session-ID model later —
it complements, not replaces, the Windows broker; tmux-in-WSL remains
the incumbent user workaround in the meantime.

**Windows Terminal (the boundary marker).** WT deliberately stopped at
text: buffer restore snapshots the screen as VT text and restores it at
launch — processes are not preserved
([WT Preview 1.21 release](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-21-release/),
[4sysops overview](https://4sysops.com/archives/new-in-windows-terminal-restore-buffers-code-snippets-scratchpad-and-regex/)),
because process durability requires exactly the server/broker WT has
only as an open proposal
([#20077](https://github.com/microsoft/terminal/issues/20077)). That is
the line winghostty would be crossing first among native Windows
terminals.
