# Deep dive: Rio

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

What are Rio's (raphamorim/rio, Rust/WebGPU) strengths, weaknesses, and
blind-spot lessons for winghostty, per [rubric](../rubric.md)? A young
cross-platform GPU terminal with real Windows support and fast
iteration: probe its WebGPU rendering bet, feature velocity, and
whether its trajectory threatens the same user winghostty targets.
Report: `research/rio.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/rio.md`](../research/rio.md).

Rio is a single-author (~97% of commits), extremely fast-moving Rust terminal whose WebGPU bet is half-walked-back: macOS/Linux now get native Metal/Vulkan backends while Windows still rides the wgpu translation layer and accumulates open rendering/input bugs. It has real Windows distribution (MSI/portable x64+ARM64, winget/choco/scoop) and deep VT/graphics capability (all three image protocols, kitty keyboard, DEC 2027), but no session restore, profiles, palette, WSL story, or signed binaries — and its polished workflow layer (session restore, quick terminal, command bar) shipped in the closed-source macOS-only Canario spin-off instead of Rio. It does not threaten winghostty's benchmark Windows user today, but its velocity plus the embeddable rio-vt/librio/WASM engine make it the fastest-moving adjacent competitor to monitor.
