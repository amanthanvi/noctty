# Deep dive: Windows Terminal

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at charting, 2026-08-17)
- Blocked-by: (none)

## Question

What are Windows Terminal's (microsoft/terminal) strengths, weaknesses,
and blind-spot lessons for winghostty, per [rubric](../rubric.md)? It is
the default incumbent every Windows user compares against; PRODUCT.md
explicitly refuses to be "a Windows Terminal clone differentiated only
by styling," so pay special attention to what the incumbent does that
users consider table stakes, where its issue tracker shows chronic
pain (performance, tabs, settings), and what its roadmap signals.
Report: `research/windows-terminal.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/windows-terminal.md`](../research/windows-terminal.md).

Windows Terminal is a preinstalled, OS-integrated incumbent maintained by a ~6-person Microsoft team whose momentum is visibly slowing (quarterly cadence paused "for reliability and performance", 1.26 delayed, 1.6k open issues). It fixed its worst folklore problems — AtlasEngine is default, the 1.22 ConPTY rewrite claimed 2-16x throughput, Sixel and the Kitty keyboard protocol shipped — but chronic weaknesses persist: ~2x-conhost input latency, multi-second XAML/MSIX cold start, a settings system so sprawling 1.25's headline feature was settings search, text-only session restore, and zero extensibility. The exploitable space is exactly winghostty's PRODUCT.md thesis: measured instantaneous native feel, transactional reliability, deep session restore, and Kitty graphics (still an open WT issue).
