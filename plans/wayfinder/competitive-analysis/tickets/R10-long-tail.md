# Field sweep: long-tail Windows terminals

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

Across the long tail of Windows-capable terminals — Wave Terminal,
Fluent Terminal, Contour, Hyper, Termius, mintty/WSLtty, Extraterm,
kitty-on-WSL, and anything else notable found while sweeping — is there
any idea, feature, or trajectory the nine deep dives would miss that
belongs in winghostty's blind-spot list? Shallow per product (a
paragraph each, not the full rubric), but flag explicitly: (a) any
blind-spot candidate for the synthesis, and (b) any product that
deserves promotion to a full deep dive. Report:
`research/long-tail.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/long-tail.md`](../research/long-tail.md).

The long tail contains no head-on rival for the benchmark user, but three payloads the nine deep dives miss: a swarm of community ghostty-windows native ports (adilahmeddev windows-apprt lineage, daily-driver-stable since March 2026) contesting winghostty's exact niche; a category drift where Wave/yaw/Termius/MobaXterm turn the terminal into an infrastructure workspace (widgets, durable sessions, SSH/DB managers, enterprise auth, sync); and idea donors — Contour (modal input, daemon/attach sessions, VT standards work), Extraterm (non-AI output framing, scroll minimap), mintty (Unicode currency, the winnable Git Bash install base). Promotion candidates for full deep dives: Wave Terminal and the ghostty-windows fork family. Fluent Terminal and Hyper are corpses proving chrome-only differentiation and Electron ceilings are fatal.
