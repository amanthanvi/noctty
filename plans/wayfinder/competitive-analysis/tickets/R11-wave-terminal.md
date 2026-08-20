# Deep dive: Wave Terminal

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at graduation, 2026-08-17)
- Blocked-by: (none)

## Question

Promoted from the long-tail sweep, which flagged Wave as the leading
example of the category drifting from "terminal emulator" to
"infrastructure workspace" (widgets, durable sessions, file
previews/editing, AI panes, remote connection management). What are
Wave Terminal's strengths, weaknesses, and blind-spot lessons for
noctty, per [rubric](../rubric.md)? Probe especially: which
workspace ideas the keyboard-first Windows dev actually values vs.
rejects, its Windows build quality (Electron), and whether the
category drift threatens or validates PRODUCT.md's terminal-first
frame. Report: `research/wave-terminal.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/wave-terminal.md`](../research/wave-terminal.md).

Wave Terminal (Command Line Inc, Apache-2.0, Electron+Go, 22.1k stars) is the flagship "terminal as infrastructure workspace" bet — blocks/widgets, SSH-durable sessions, AI-first roadmap — but its own issue tracker shows keyboard-first users asking it to be more like a terminal: no graphics protocol or synchronized output (xterm.js ceiling), non-rebindable keys, WSL modeled as a flaky remote connection, x64-only Windows, ConPTY outsourced to a stale 2023 fork. Headline new finding: development has stalled — no release since v0.14.5 (2026-04-16) and zero public commits from founder Mike Sawka anywhere since 2026-05-10, with the repo coasting on dependabot against 451 open issues. Verdict: Wave validates noctty's terminal-first frame; adopt its durable-session, scriptability, and quake-mode ideas piecemeal, and exploit its Electron/VT/keybinding weaknesses directly.
