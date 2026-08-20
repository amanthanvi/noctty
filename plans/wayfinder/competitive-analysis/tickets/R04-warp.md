# Deep dive: Warp on Windows

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

What are Warp's (Windows build) strengths, weaknesses, and blind-spot
lessons for winghostty, per [rubric](../rubric.md)? Warp competes on a
different axis — AI/agentic workflows, block-based output, team
features, closed source — and is the loudest signal of where the
terminal category is being pulled. Probe: which Warp ideas the benchmark
user actually values vs. rejects (telemetry, login requirements),
and whether any belong in winghostty's frame at all.
Report: `research/warp.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/warp.md`](../research/warp.md).

Warp is the $73M-funded category-definer for the "agentic development environment": blocks, agent mode, hosted CLI agents, and team-shared workflows, with its Rust client open-sourced (AGPL+MIT) in April 2026 while the Oz agent cloud stays proprietary. Its Windows build (Feb 2025, forked ConPTY, PowerShell/WSL/Git Bash, no cmd.exe) is credible but carries a non-native winit chrome tax, memory-leak and GPU-driver crash themes, WSL gaps, and forced auto-update. The keyboard-first Windows dev values its workflow objects (quake window, named layouts, restored scrollback, saved commands) while rejecting its cloud coupling, telemetry history, shell-editor takeover, and AI pricing whiplash — a near-perfect map of what winghostty should steal versus loudly not do.
