# Shared Deep-Dive Rubric

Every research dive answers the same ten sections, in this order, so
findings aggregate into one ranked list at synthesis. Judge against
[PRODUCT.md](../../../PRODUCT.md)'s benchmark user: a keyboard-first
Windows developer moving between PowerShell and WSL, running tabs,
splits, long-lived shells and TUIs, expecting session layout to survive
restarts, valuing native behavior, immediate feedback, and deep terminal
capability over cross-platform uniformity.

Evidence standard: research only — the product's repo (code, commits,
issues, discussions, PRs), official docs and changelogs, release
artifacts, and credible third-party reports/benchmarks. Cite sources
(URLs) for every load-bearing claim. Mark anything uncertain as such
rather than guessing. No hands-on claims.

## Sections

1. **Identity & strategy** — what it is, who it targets, stated
   differentiators, relationship to upstream(s), governance/bus factor,
   license.
2. **Performance & fluidity** — rendering architecture (API, threading,
   damage model), latency/throughput claims and any published
   benchmarks, animation/scroll smoothness approach, startup time.
3. **Native Windows integration** — window chrome/backdrops, Snap
   Layouts, jump lists, taskbar progress, notifications,
   default-terminal registration, shell/Explorer integration, ARM64,
   ConPTY vs. custom pty handling, WSL story, elevation/UAC handling.
4. **Terminal capability** — VT conformance depth, graphics protocols
   (Kitty/sixel/iTerm2), hyperlinks, clipboard OSCs, mouse modes,
   shell integration (prompt marks, cwd, command duration), search,
   scrollback model.
5. **Workflow features** — tabs, splits, session restore, command
   palette, quick/dropdown terminal, profiles, keybinding model,
   broadcast input, anything workflow-shaped the benchmark user touches
   daily.
6. **Reliability & quality signals** — dominant issue-tracker themes,
   crash/regression patterns, test and CI story, release stability
   reputation.
7. **Configuration & extensibility** — config model (file/GUI/both),
   live reload, theming, scripting/plugin/API surface.
8. **Packaging & adoption** — install channels (winget, Scoop, MSIX,
   portable), update mechanism, code signing, docs site quality,
   onboarding friction, stars/contributors/release cadence as momentum
   signals.
9. **What users complain about** — top recurring negative themes from
   issues, discussions, Reddit/HN, reviews. Quote or link concrete
   instances.
10. **Lessons for winghostty** — the payload. Three explicit lists:
    - *Does well (adopt-candidates):* things winghostty measurably lacks
      or does worse, per [docs/status.md](../../../docs/status.md) and
      [docs/windows-capability-matrix.md](../../../docs/windows-capability-matrix.md).
    - *Does badly (avoid/exploit):* failures winghostty can learn from
      or differentiate against.
    - *Blind-spot candidates:* things this product considers that
      winghostty's PRODUCT.md doesn't even have a category for.

## Report format

One markdown file per dive in `research/<slug>.md`, headed by a
five-line executive summary, then the ten sections. Keep it dense and
sourced; synthesis reads all ten reports in one context.
