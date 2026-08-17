# Synthesis: ranked gap list

- Label: wayfinder:research
- Status: closed
- Assignee: synthesis subagent (fired 2026-08-17)
- Blocked-by: R01, R02, R03, R04, R05, R06, R07, R08, R09, R10, R11, R12

## Question

Cross-referencing all ten research reports against winghostty's actual
current state (docs/status.md, docs/windows-capability-matrix.md,
PRODUCT.md, DESIGN.md), what is the deduplicated, ranked list of
candidate gaps, opportunities, and blind spots for the decision session?
Each candidate: what it is, which competitors evidence it, why it
matters to the benchmark user, rough cost intuition, and a provisional
adopt/reject/defer recommendation with rationale — the decision session
rules; this ticket only ranks and recommends. Also list findings that
challenge PRODUCT.md's frame itself, separately. Output:
`research/synthesis.md`.

## Resolution

Resolved 2026-08-17 by synthesis subagent. Full ranked list:
[`research/synthesis.md`](../research/synthesis.md).

37 candidates (26 provisional adopts, 11 defers), 9 frame challenges
proposing PRODUCT.md amendments, and 11 explicit rejects staged for
fast ratification. Highest-leverage adopts: published Windows
benchmarks + CI gates (C01), docs accuracy (C04 — code verification
confirmed status.md materially undersells the product: quick terminal
+ global hotkey, WinRT toasts, taskbar progress, and docked search all
already exist in `src/apprt/`, so six reports' claimed "gaps" deduped
into one documentation candidate), bundled newer OpenConsole
`conpty.dll` with degraded-mode logging (C05), OS entry points
(default-terminal registration, jump lists, Explorer menu; C11–C13),
and scrollback-content restore (C15). Highest-impact defer: durable
process-surviving sessions (C16, XL, needs a feasibility spike).
Decision-first frame items: naming/trademark risk (F1) and
upstream-relations posture (F2). No competitor healthily occupies
winghostty's niche today; the live threats are upstream's trademark
statement and upstream's libghostty/tiered-Windows convergence
(12–24 month window).
