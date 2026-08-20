# Deep dive: Alacritty

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

What are Alacritty's strengths, weaknesses, and blind-spot lessons for
winghostty, per [rubric](../rubric.md)? It is the minimal-fast
benchmark: GPU rendering, deliberate feature refusal (no tabs/splits),
strong performance reputation. Probe what its discipline buys it, what
its Windows experience actually is (ConPTY handling, packaging), and
where "fast but spartan" loses the benchmark user.
Report: `research/alacritty.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/alacritty.md`](../research/alacritty.md).

Alacritty (Rust/OpenGL, 65k stars, two maintainers, v0.17.0 Apr 2026) is the minimal-fast benchmark: it refuses tabs, splits, scrollback UI, ligatures, graphics, and shell integration by policy, and the discipline buys a 2.3 MB MSI, near-top latency/throughput, and a clean ~330-issue tracker. But its speed is no longer unique (Ghostty/kitty match it), and on Windows it is tier-2: unsigned binaries, no ARM64, no colored emoji since 2019, unix-only daemon/IPC, and a "use tmux for tabs" answer that structurally fails because tmux doesn't run on native Windows — leaving exactly winghostty's benchmark user unserved.
