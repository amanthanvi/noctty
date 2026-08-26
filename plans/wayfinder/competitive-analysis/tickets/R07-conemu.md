# Deep dive: ConEmu / Cmder

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

What are ConEmu's (and the Cmder distribution's) strengths, weaknesses,
and blind-spot lessons for noctty, per [rubric](../rubric.md)? The
long-reigning pre-ConPTY power terminal: probe the deep Windows-specific
affordances it accumulated over a decade (window docking, quake mode,
task/profile system, integration hooks) that newer terminals dropped,
what kept loyal users, and what its decline teaches about maintenance
and momentum. Report: `research/conemu.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/conemu.md`](../research/conemu.md).

ConEmu was the decade-reigning pre-ConPTY Windows power terminal: it faked modern terminal behavior on hidden conhost buffers via DLL injection (ConEmuHk) and in the process invented Windows affordances no successor has fully matched — elevated tabs in one window, quake mode with multi-monitor summon, a task system fusing profile+layout+hotkey, taskbar jump lists, and the OSC 9;4 progress protocol now adopted by Windows Terminal and Ghostty. Its architecture became its ceiling (AV false positives, hook conflicts, GDI rendering, ANSI limited to the visible area), and with a bus factor of 1 it slid into maintenance twilight: last stable release July 2023, unreleased fixes on master since April 2025, ~1.1k open issues. Cmder — an opinionated portable distribution wrapping ConEmu with clink and a git-aware prompt — out-starred the engine 27k to 9.2k, proving defaults and packaging multiply distribution, and now survives by running inside Windows Terminal.
