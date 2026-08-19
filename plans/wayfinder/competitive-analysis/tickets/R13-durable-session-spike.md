# Spike: durable-session feasibility

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired 2026-08-19)
- Blocked-by: (none)

## Question

Spawned by the decision session's C16 defer-with-spike ruling and the
F6 session-promise tiers (process durability is now a named
aspiration). Can shells and TUIs running under winghostty survive a UI
process restart on Windows, and what would reattach require? Probe,
research-only: ConPTY handle/process lifetime semantics (what dies
with the creating process; can a ConPTY be inherited, duplicated, or
re-owned by a broker/daemon process); the broker-process architecture
options and their costs (a separate session-host process owning ConPTYs
+ an IPC/reattach protocol vs. OS-level tricks); how WezTerm's mux
domains, Wave's SSH-durable job manager, Contour's daemon mode, and
ghostinthewsl's VSOCK bridge each solve or dodge this; scrollback
ownership during detach; and the failure modes (crash of the broker,
update of the broker, elevation boundaries). Deliverable: a feasibility
verdict (feasible-with-broker / feasible-only-for-WSL / infeasible),
the minimal viable architecture sketch if feasible, and the cost class
(confirming or revising the XL estimate). Report:
`research/durable-session-spike.md`.

## Resolution

Resolved 2026-08-19 by research subagent. Full report:
[`research/durable-session-spike.md`](../research/durable-session-spike.md).

**Verdict: feasible-with-broker.** The `HPCON` dies with its owning
process (kernel handle close → conhost teardown → CTRL_CLOSE_EVENT
kills clients; no OpenPseudoConsole-style re-acquire API exists), so
durability requires a session-host process owning ConPTYs + children,
with the UI attaching over named pipes — proven, shipped art (VS
Code's pty host; Windows Terminal's #20077 proposal;
`ConptyPackPseudoConsole` handoff). Ceiling: survives UI
restarts/crashes within a logon session, never logoff/reboot; a broker
crash still kills sessions.

**Cost class: XL confirmed** for the graduated feature (broker
lifecycle, versioned protocol, elevation policy, ring-buffer/replay) —
but it is known engineering, not research risk; winghostty's termio
already consumes plain pipe handles, so attach is a one-seam
substitution in `Subprocess.start`.

**Smallest testable increment (M):** a standalone `conpty-host` spike
exe (reusing `pty.zig`/`Command.zig`) that owns one pwsh-under-ConPTY,
ring-buffers output, and serves a named pipe; test = attach, run a
TUI, hard-kill the client, reattach, confirm the shell survived and
the viewport repaints on a resize nudge. Whether/when to fund this
increment is a roadmap decision for the assembly ticket (T01), under
F6's durability-aspiration tier.
