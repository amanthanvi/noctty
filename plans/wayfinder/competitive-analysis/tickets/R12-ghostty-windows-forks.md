# Deep dive: ghostty-windows community fork family

- Label: wayfinder:research
- Status: closed
- Assignee: research subagent (fired at graduation, 2026-08-17)
- Blocked-by: (none)

## Question

Promoted from the long-tail sweep, which found a swarm of community
Ghostty Windows-port efforts (the adilahmeddev windows-apprt lineage
and related forks, reportedly daily-driver-stable since March 2026)
contesting winghostty's exact niche — a rival family the nine deep
dives missed entirely. Per [rubric](../rubric.md): map the family (who,
which forks, activity, architecture), how far each actually is
(features vs. claims), their distribution/trust story, community
traction, and relationship to upstream. The strategic payload: is any
of these likelier than winghostty or wintty to become "the" Ghostty on
Windows, what do they do that winghostty lacks, and does a
fragmented fork field change winghostty's positioning or
upstream-relations posture? Report: `research/ghostty-windows-forks.md`.

## Resolution

Resolved 2026-08-17 by research subagent. Full report:
[`research/ghostty-windows-forks.md`](../research/ghostty-windows-forks.md).

The adilahmeddev windows-apprt lineage is real but decaying: the root fork is deleted/private, zcg/ghostty-win archived itself as abandoned AI-era work, Thr45hx (59 stars) is a frozen unsigned one-release snapshot, and the most active hard fork (shiweis, 38 stars) ships no binaries at all — no fork out-tracks winghostty (255 stars, signed releases, winget/Scoop). The real contest for "THE Ghostty on Windows" is upstream itself: Windows CI since Dec 2025, an Apr 2026 tier plan (D3D renderer, Win10/11, minimal C++), mattn actively on Tier 2, wintty's 17 merged PRs, and mitchellh steering everything toward libghostty consumers (mite, hollow, winterm-ghostty). Critical direct finding: a Ghostty maintainer stated on Jul 12 2026 — prompted by a question about winghostty specifically — that unaffiliated projects must not use "Ghostty" in their branding (nonprofit-owned trademark), making winghostty's name a live rename risk. Full report at plans/wayfinder/competitive-analysis/research/ghostty-windows-forks.md.
