# Spike: durable-session feasibility (C16 / F6 process-durability aspiration)

Research date: 2026-08-19. Resolves ticket
[R13](../tickets/R13-durable-session-spike.md). Method: primary-source
research (Microsoft console docs, microsoft/terminal source and issues,
competitor docs/issues) plus local code reading (`src/pty.zig`,
`src/termio/Exec.zig`, `src/Command.zig`, `src/apprt/win32_session_*.zig`).
The original research sections did not run experiments; every
load-bearing external claim carries a URL. The dated feasibility
increment appended below records the later local experiment. Uncertainty
is marked inline.

## Executive summary (verdict first)

**Verdict: feasible-with-broker.** ConPTY sessions die with the process
that holds the `HPCON` — there is no OS-level way to park a session and
re-open it later by name — so shells surviving a UI restart require a
separate session-host process that owns the ConPTYs and child processes,
with the UI attaching over named pipes. This is proven, shipped art on
Windows (VS Code's pty host does exactly this with ConPTY today), the
handle-handoff mechanics are demonstrated by Windows' own defterm handoff,
and noctty's termio already treats the Windows pty as a plain pair of
pipe handles, which is precisely the shape a broker attach needs. **Cost
class: XL confirmed** for the full feature (broker lifecycle, reattach
protocol, scrollback ownership, failure modes), but the smallest testable
increment — a standalone conpty-host spike proving kill-UI/reattach — is
an M and should be built before any noctty integration.

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
The session outlives the _shell_; it does not outlive its _owner_.

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
Any user-mode broker gives durability _across UI restarts within a
logon session_ — not across logoff/reboot. Cross-reboot durability
would need a service in session 0 hosting interactive ptys, which is
out of scope and hostile territory.

## 2. Where noctty stands today (code reading)

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

**A. Session-host broker (recommended).** A separate noctty-session
process (same codebase, second exe or `--session-host` mode) owns
`Pty.open`, `Command` spawn, the Job Object, and a bounded raw-VT ring
buffer per session; the UI connects over a named pipe (per-user
access is enforced by an owning-user DACL, not by the pipe-name
namespace), speaking a small protocol:
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
makes adoption _possible_, but only broker-shaped processes can use it.

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
(the benchmark noctty user) get nothing. Reasonable as a _later_
fidelity upgrade for WSL profiles, not as the answer to F6.

### Minimal-viable sketch for noctty (option A)

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
  session ID per leaf; restore flow tries reattach and falls back to fresh spawn only on an explicit broker not-found — preserving `win32_session_persistence.zig`'s `LoadResult` distinctions (missing/oversized/transient/corrupt/loaded): transient broker startup/timeout/protocol failures are retried rather than respawned, and old records or stale broker IDs degrade to layout-only restore, so a transient attach failure can never leave the original session running while the UI spawns a duplicate shell. Durability degrades to today's layout-only restore, never worse.
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
  Pipe DACLs must restrict to the owning user; separate broker instances
  enforce the integrity-level boundary.
- **Scrollback ownership during detach:** while no UI is attached,
  _someone_ must drain the output pipe (otherwise child output
  backpressures; pre-24H2, close paths can deadlock —
  [ClosePseudoConsole](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole)).
  The broker's ring buffer is therefore mandatory, not an optimization.
  Replay fidelity is bounded: alt-screen TUIs won't replay perfectly
  from a byte ring (VS Code caps restored scrollback and accepts this;
  [docs](https://code.visualstudio.com/docs/terminal/advanced)). The
  feasibility increment below shows that a live polling TUI can observe
  a resize nudge and emit a fresh cursor-addressed redraw; it does not
  establish a generic ConPTY-driven repaint guarantee for arbitrary
  TUIs. Full fidelity = option C's cost.
- **Job objects / orphan control:** the `KILL_ON_JOB_CLOSE` job must be
  owned by the broker, and "close all sessions on real quit" becomes an
  explicit broker verb — otherwise durable sessions become orphan
  leaks users blame on noctty.
- **Logoff/reboot:** not survivable by design (§1); the feature must be
  honestly scoped as "survives UI restarts and crashes," composing with
  the existing layout restore for the reboot case.

## 5. Cost class and smallest testable increment

**XL confirmed** for the graduated feature (broker lifecycle +
versioned protocol + reattach UX + elevation policy + ring
buffer/replay + update strategy + tests). It is an XL of mostly _known_
engineering, though — the OS facts are settled and the pattern is
shipped art (VS Code), not research risk.

**Smallest testable increment (M):** a standalone `conpty-host` spike —
one Zig exe reusing `pty.zig`+`Command.zig` that spawns pwsh under a
ConPTY it owns, ring-buffers output, and serves one named pipe; plus a
trivial attach client. Test: attach, run a synthetic alt-screen TUI,
hard-kill the client, reattach from a new client, confirm the shell and
TUI survived, and receive a cursor-addressed redraw containing the same
pre-kill content after a resize nudge. Bounded-buffer acceptance
criterion: a fixed-size per-session ring (default 1 MiB, configurable)
that overwrites oldest data on overflow, replays its full contents on
attach, and is tested by generating more output than the ring holds
while detached — reattach must show the newest data, retained ring bytes
must never exceed the cap, and process-private-memory growth is recorded
as a one-run diagnostic rather than a guarantee. That one artifact retires the
core risk (lifetime semantics, drain-while-detached, replay adequacy)
before any noctty integration, and its protocol can be thrown away.
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
liability; noctty should start with the thin broker and bounded
buffers, and treat mux-grade fidelity as a separate future decision.

**Wave job manager.** Wave ships durability _only_ where it's easy — a
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
settling") — uncertain, and noctty should assume no one has proven
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
the line noctty would be crossing first among native Windows
terminals.

## Feasibility increment result (2026-08-21)

**Verdict: GREEN.** The broker shape works on the tested Windows 25H2
build 26200.9168. The opt-in `conpty-host` spike is one console
executable with `serve` and `attach` modes. The host directly reuses
`Pty.open` / `WindowsPty` from `src/pty.zig` and the ConPTY launch path
in `src/Command.zig`, owns one `pwsh.exe`, drains ConPTY output on a
dedicated thread even with no client, retains raw output in a
preallocated 1 MiB overwrite ring, and accepts one client at a time on
a named pipe. Its actual security controls are an explicit protected
current-user SDDL DACL, `FILE_FLAG_FIRST_PIPE_INSTANCE`,
`PIPE_REJECT_REMOTE_CLIENTS`, a single pipe instance created before the
name is advertised and held for the host's lifetime, clients that
connect at `SECURITY_IDENTIFICATION`, and clients that authenticate the
server's owner SID before sending any frame. The retained `LOCAL` prefix only affects
AppContainer name resolution; it is not an access-control property for
ordinary desktop processes. Its deliberately disposable protocol has
only attach, detach, resize, input, and output frames.

`test/windows/conpty-host-spike.ps1` asserted the experiment end to
end. It started and recorded every process it controlled; attached to
the shell; recorded the shell PID and a shell variable; entered the
alternate screen with `CSI ?1049h`; and ran a synthetic polling TUI that
drew a cursor-addressed box containing a unique content token at 80x24.
It force-killed the exact first client PID while that TUI was active,
proved the shell PID remained live, attached a fresh client, and resized
from 80x24 to 100x31. The new client then received a normalized
cursor-addressed redraw containing the same pre-kill content token and a
new unique 100x31 redraw token, followed by `CSI ?1049l`. The 100x31
token did not exist before reattach, so it could not be old ring replay.
The script then queried and matched the original PID and shell variable,
detached again, generated more than the 1 MiB ring capacity, and
reattached to
prove the detached command's completion sentinel existed before
reattach, the client received at least the full 1 MiB retained replay,
the newest marker and completion marker were present, and the oldest
marker had been overwritten. Before that final attach, it required the
host's drained-output total to remain unchanged for 750 ms after the
shell wrote its out-of-band completion file, preventing trailing output
from satisfying the marker assertions as live traffic instead of replay.
It also checked every emitted ring stat for `retained <= capacity`,
sampled host private memory throughout detached overflow, exercised the
explicit detach frame, and cleaned up only retained process objects for
recorded PIDs.

The latest hardened green run reported:

```text
CONPTY_HOST_SPIKE_RESULT {"result":"PASS","verdict":"GREEN","host_pid":588,"killed_client_pid":47372,"shell_pid":39000,"same_shell_pid":true,"shell_state_intact":true,"alt_screen_entered":true,"alt_screen_redraw":"cursor-addressed-preexisting-content@100x31","alt_screen_exited":true,"detached_drain":true,"detached_output_completed":true,"ring_capacity_bytes":1048576,"ring_retained_bytes":1048576,"ring_total_bytes":2575370,"replay_bytes":1048576,"oldest_replay_absent":true,"newest_replay_present":true,"observed_host_private_baseline_bytes":38445056,"observed_host_private_max_detached_bytes":38445056,"observed_host_private_growth_bytes":0,"observed_private_growth_within_ring_cap":true,"pipe_security":"current-user-DACL+first-instance+reject-remote+persistent-instance+client-verifies-server-sid","pipe_security_evidence":"mechanism-inventory-not-derived","pipe_security_execution_verified":"current-user-DACL-accept;server-sid-accept;persistent-instance-reuse","pipe_security_by_construction":"first-instance-collision;reject-remote;cross-user-DACL-denial;untrusted-server-rejection","detach_frame":true,"ceiling":"same-logon-session-only;never-logoff-or-reboot"}
```

The memory evidence is intentionally precise and observational: total
process private memory was 38,445,056 bytes before detached overflow, so
the whole process was not and cannot be under a 1 MiB ring cap. The
retained-output allocation never exceeded 1,048,576 bytes, and the
sampled private-memory growth while draining at least 2,575,370 bytes
detached was 0 bytes. That figure is recorded, not enforced: the harness
reports `observed_host_private_growth_bytes` and derives
`observed_private_growth_within_ring_cap` from it, but neither can fail
the run. `PrivateMemorySize64` is whole-process private memory, so
unrelated heap or runtime page commits can move it by more than the
ring capacity while `retained <= capacity` stays true, and sampling
every 25 ms can miss a transient peak in either direction. The only
memory gate is the ring's retained-byte bound, checked on every emitted
`RING_STATS` line. An
attached client also causes a transient, capacity-sized replay snapshot;
the snapshot is copied under the ring mutex and sent after unlocking so a
slow replay cannot stop the continuously running ConPTY drain thread.

The drain thread also performs no diagnostics I/O. The `RING_STATS`
lines the harness parses are published by a separate thread that samples
the ring every 20 ms, because a synchronous stderr write on the drain
thread would block whenever stderr is a pipe whose reader stops
consuming — which would backpressure ConPTY through the very
measurement instrument used to prove detached draining.

That sampler is detached and is never joined at teardown. The same
blocking write that must stay off the drain thread would otherwise stall
shutdown instead: a thread already inside `WriteFile` cannot observe a
stop flag, so joining it would hang teardown and leave a broker alive
after its shell had exited — the one lifetime property this spike
exists to claim. Teardown therefore signals the sampler and abandons it.
Abandoning it is only safe because the ring, its backing bytes and the
sampler's context are allocated from the page allocator and never freed;
the host is a one-shot process and the OS reclaims them at exit. Keeping
them out of the GPA also stops its leak report from firing at teardown,
which would itself be another blocking write to the same stderr.

Residual unknowns remain product-sized: arbitrary third-party and
complex TUI behavior beyond this synthetic polling alt-screen probe; a
stalled attached client can still
monopolize the spike's single connection until it disconnects, although
it no longer blocks ConPTY draining; multi-session and multi-client
lifecycle; broker crashes; elevation and integrity-level separation;
upgrade/protocol migration; long-duration memory behavior; and
adversarial validation from another user or integrity level. The DACL
construction was exercised only by the owning user.

An earlier revision described the pipe-name gap as a same-user squat and
dismissed it as out of scope. That was wrong, and the correction matters.
The `\\.\pipe` namespace is machine-global, creating a name in it needs
no privilege, and the namespace is enumerable: from an ordinary process,
listing `\\.\pipe` returned 542 entries including this spike's randomly
named instance,
`\\.\pipe\LOCAL\noctty-conpty-host-probe-52876839e78448b49d07ef7589cebee7`.
An unguessable name is therefore not a control. The DACL protects the
object this host creates; it never reserves the name. So a _different,
lower-privileged_ local user — not merely a same-user process — could
have claimed the name in any window where no instance existed. This
host's `FILE_FLAG_FIRST_PIPE_INSTANCE` would fail it closed on the next
accept, but the client performs no server authentication, so a
reconnecting client would have disclosed its terminal input to the
impostor. That is a cross-user disclosure path, and it was outside what
the stated same-user scope covered.

The host now creates its one instance before advertising the name and
reuses it across clients via `DisconnectNamedPipe` and a fresh
`ConnectNamedPipe` on the same handle, so the name is never unowned
while the host lives. `DisconnectNamedPipe` discards data still buffered
in the instance, and all per-client state is local to `serveClient`, so
a new client cannot observe the previous client's bytes. Max instances
stays 1, preserving one client at a time. Clients also connect with
`SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`, which caps the token
a server can obtain from a connecting client at identification level:
the server can still obtain such a token and learn who the client is,
but it cannot act as the client. Without the SQOS flags the default is
`SecurityImpersonation`, which would let it.

This reuse is not only a design change; it is execution-verified. Every
green run drives four successive reattaches (clients 2 through 5,
including one after a hard PID kill) through the
`DisconnectNamedPipe` → `ConnectNamedPipe` path on the same handle, so
the reused instance is exercised on the normal path of every run rather
than reasoned about.

One caveat about the evidence itself, so the verdict line is not read
for more than it says: `pipe_security` is a hard-coded constant in the
harness. It is a fair inventory of mechanisms that all exist in the
code, but it is not derived — deleting `verifyPipeServer` from the
client would not change the emitted string, and the harness's only
related assertion regexes the host's own `security=current-user`
self-report. Of the listed tokens, only the current-user DACL accept
path, the server-SID accept path and the persistent-instance reuse are
execution-verified. First-instance collision, reject-remote, cross-user
DACL denial and the `UntrustedPipeServer` rejection branch hold by
construction and code review only. The run now emits
`pipe_security_evidence`, `pipe_security_execution_verified` and
`pipe_security_by_construction` so this distinction travels with the
result. If any of this graduates to product, the field must be derived
from probes rather than asserted.

A second correction is needed, because the revision that introduced the
persistent instance then claimed the remaining cases were "fail closed,
no disclosure". That was also wrong. `FILE_FLAG_FIRST_PIPE_INSTANCE`
fails the _host_ closed; it says nothing about the _client_. When an
attacker owns the name before the host starts, or when `attach` runs
with no host at all, the client's open still succeeds against the
attacker's pipe and the client then sends its attach frame and its
stdin. Confirmed directly: with no host running and an impostor holding
`\\.\pipe\LOCAL\noctty-conpty-host-<name>`, the client connected and the
impostor received the attach frame `01 00 00 00 00`. That is disclosure,
not denial of service, and `SECURITY_IDENTIFICATION` does not help — it
stops the server acting as the client; it does nothing about capture.

So the client now authenticates the server before sending any frame:
`GetNamedPipeServerProcessId` on the opened handle, then `OpenProcess`,
then a token-user SID comparison against the current user, failing
closed as `error.UntrustedPipeServer` on any step it cannot positively
confirm — including an `OpenProcess` that fails because the server
belongs to another user. The green run below exercised the accepting
path across all five clients.

What remains is now stated exactly. This closes the cross-user case up
to a PID-reuse race between the pipe's recorded server PID and
`OpenProcess`: the check authenticates the process currently holding
that PID, not the pipe endpoint itself. An attacker can create the
instance in a short-lived process, `DuplicateHandle` the server end into
a long-lived one, let the creator exit, and groom PID reuse so a
victim-user process holds that PID when `OpenProcess` runs. That is
esoteric and race-dependent, but it is why the claim is bounded rather
than absolute. There is no TOCTOU _after_ the check — the handle stays
bound to the verified instance. A same-user impostor still passes
outright, as does a same-user impostor at a different integrity level;
integrity-level separation stays on the residual list above.

The accept is cancellable. The host's instance is created with
`FILE_FLAG_OVERLAPPED`, `ConnectNamedPipe` is issued with an
`OVERLAPPED` event, and the host waits on that event and the shell's
process handle together; when the shell exits first the pending accept
is cancelled with `CancelIoEx`, its completion is awaited, and teardown
proceeds. An earlier revision used a synchronous accept, so a shell
that exited with no client attached left the host parked until some
client happened to connect. The wait/select logic is covered by four
hermetic Zig tests in `src/conpty_host.zig` (client connected before
the accept, client connecting during the accept, shell exit cancelling
a pending accept and leaving the instance reusable, and shell exit
winning while the accept is pending), using an event in place of the
process handle. The end-to-end case is asserted by the harness as its
final stage: a sixth client sends `exit` to the shell and detaches on
EOF, so the shell dies with no client attached, and the run requires
the host process to exit on its own with code 0 within ten seconds
(`shell_exit_released_host`, `host_exit_code`). Because the instance is
overlapped, every host-side pipe read and write is now issued
overlapped as well, each awaited on the same event before returning.
No application integration was attempted.

The ceiling is unchanged and absolute: this design can survive UI
restarts and crashes only while the broker remains alive in the same
logon session. It can never survive logoff or reboot, and a broker crash
still kills its ConPTY and shell. With that ceiling, deferred C16
durable-session planning may graduate; the XL implementation remains
unscheduled.
