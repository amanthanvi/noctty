# Deep dive: upstream Ghostty parity

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

Where has upstream Ghostty (ghostty-org/ghostty) moved since this fork
diverged, and what does the divergence cost or buy noctty, per
[rubric](../rubric.md) (adapted: "competitor" = upstream's current
state)? Probe: terminal-core features, VT/graphics work, performance
work, and config surface added upstream that this hard fork has not
pulled; upstream's roadmap signals (libghostty, GTK rewrite, Windows
plans if any); and the strategic contrast with wintty's daily-rebase
soft-fork model. Ground the noctty side in docs/status.md and
docs/windows-capability-matrix.md. Report:
`research/upstream-ghostty.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/upstream-ghostty.md`](../research/upstream-ghostty.md).

Upstream Ghostty (60k stars, MIT, now non-profit) shipped 1.3.0 in March 2026, but noctty's core is already synced to a 1.3.2-dev baseline — the real delta is ~5 months of unmerged main-branch work plus the 1.4 wave (Sept 2026: scriptability, GUI tmux control mode, graphical preferences) and the strategic shift to libghostty (C API, Wasm, Windows CI). Windows GUI support remains "still not planned" with only a non-committal Nov/Dec 2026 exploration slot, giving noctty a 12-24 month window as the definitive Ghostty-on-Windows; meanwhile upstream's April 2026 GitHub exodus (destination unannounced) and libghostty source extraction will raise the hard fork's merge costs. Upstream's durable weaknesses — no Windows, battery/power blind spot, Zig-churn packaging fragility, regression-heavy 6-month releases — are all exploitable.
