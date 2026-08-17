# Deep dive: Tabby

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

What are Tabby's (Eugeny/tabby, Electron) strengths, weaknesses, and
blind-spot lessons for winghostty, per [rubric](../rubric.md)? Tabby
wins users despite Electron weight — probe why: its SSH/serial/profile
management, plugin ecosystem, and GUI-first configurability are the
blind-spot candidates; its performance and memory complaints are the
differentiation openings. Report: `research/tabby.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/tabby.md`](../research/tabby.md).

Tabby (~74k stars, MIT, single-maintainer Electron/Angular/xterm.js app) wins Windows users despite its weight because it bundles a PuTTY-class SSH/serial/telnet connection manager, an encrypted secrets vault, GUI-first settings, quake mode, portable mode, and an npm plugin manager into one app — proving Windows devs will pay a heavy performance tax for managed-connection workflow value. That tax is structural and well documented: 200-400MB idle RAM, ~740MB GPU RAM vs Windows Terminal's 32MB, 30-60s startup pathologies, 15GB leak reports, plus SSH regressions, recurring injection/traversal CVE-class fixes, a 2.7k-issue backlog, and an abandoned official sync service. winghostty can deliver the workflow value (connections, vault, quake mode, deep links) natively without the tax, and should publicly benchmark against Tabby's own pain numbers.
