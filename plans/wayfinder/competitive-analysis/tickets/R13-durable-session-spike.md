# Spike: durable-session feasibility

- Label: wayfinder:research
- Status: open
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
