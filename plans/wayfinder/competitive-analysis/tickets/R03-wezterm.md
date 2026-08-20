# Deep dive: WezTerm

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

What are WezTerm's strengths, weaknesses, and blind-spot lessons for
noctty, per [rubric](../rubric.md)? It is the strongest
cross-platform power-user terminal on Windows (Lua config, multiplexing,
SSH domains, excellent font handling); probe especially its
multiplexer/domain model and scripting surface as blind-spot candidates,
and its Windows-specific rough edges as differentiation openings.
Report: `research/wezterm.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/wezterm.md`](../research/wezterm.md).

WezTerm remains the strongest cross-platform power-user terminal on Windows, differentiated by a full Lua scripting/plugin surface and built-in multiplexing (local/SSH/TLS/WSL domains with detach-reattach) plus a native SSH client — but Windows is visibly a port: minute-scale startup stalls, no default-terminal handoff, no native ARM64, GiB-scale memory reports, and non-conformant opt-in Kitty protocol support. The project is alive (near-daily commits Aug 2026, contributor "bew" now dominating alongside wez) yet has shipped no stable release since 2024-02, leaving winget/Scoop users 2.5 years behind and prompting "is this dead?" issues.
