# Winghostty Competitive Analysis Map

Wayfinder map (`wayfinder:map`). Tracker: local markdown (this repo forbids
GitHub issues per AGENTS.md). Tickets are files in
[`tickets/`](tickets/); a ticket is claimed by filling its `Assignee`
field, closed by setting `Status: closed` and appending a
`## Resolution` section. A ticket is unblocked when every ticket in its
`Blocked-by` list is closed. Research reports land in
[`research/`](research/).

## Destination

A decided, prioritized competitive-response roadmap committed to this
repo: for each competitor strength, weakness, or blind spot the analysis
surfaces, an explicit adopt / reject / defer decision with rationale,
ready to hand to `/implement`. The analysis report is an input, not the
deliverable.

## Notes

- Domain: Windows terminal emulators. Winghostty is a Windows-only hard
  fork of Ghostty (Zig, native Win32 apprt, OpenGL/DirectComposition).
- Judging frame: [PRODUCT.md](../../../PRODUCT.md) benchmark user and
  principles are the default lens, **amendable** — findings that
  challenge the positioning itself become explicit roadmap decision
  items, not silent reframes.
- Scope covers **product and adoption** (distribution, docs,
  onboarding, community momentum), not just what the running terminal
  does.
- Evidence standard: **research only** — repos, docs, issue trackers,
  changelogs, third-party reports. No hands-on evaluation (consciously
  ruled out; see Out of scope).
- All deep dives share the rubric in [rubric.md](rubric.md) so findings
  aggregate; each dive ends with an explicit "Lessons for winghostty"
  section (does well / does badly / blind-spot candidates).
- Skills for HITL tickets: `/grilling`, `/batch-grill-me`,
  `/domain-modeling`.
- Standing preference: decisions, not deliverables — implementation of
  roadmap items happens outside this map.

## Decisions so far

<!-- one line per closed ticket: gist + link to the ticket holding the detail -->

- Charting decisions (this session, recorded here since they predate the
  tickets): destination = decided roadmap; nine deep dives + long-tail
  sweep, everything-deep; research-only evidence; rubric drafted at
  charting; PRODUCT.md default-but-amendable; product + adoption scope;
  synthesize-then-batch-grill decision flow.

## Not yet specified

<!-- in-scope fog; graduates into tickets as the frontier advances -->

- Individual grilling tickets for roadmap items too big or contentious
  to settle in the batch decision session — which items, if any, emerge
  from [Decision session: adopt/reject/defer](tickets/D01-decision-session.md).
- Possible PRODUCT.md amendment decisions, if the dives expose flaws in
  the positioning frame itself.
- Possible promotion of a long-tail product to a full deep dive, if the
  sweep flags one as a real rival.
- Shape and location of the final roadmap document (likely
  `plans/2026-competitive-roadmap.md`; confirm at assembly time).

## Out of scope

<!-- ruled beyond the destination; never graduates -->

- Hands-on evaluation of competitors on a real Windows machine —
  consciously ruled out at charting; all claims stay research-sourced.
- Implementing any roadmap item — this map ends when decisions are made.
- Marketing/community *execution* (writing posts, running outreach);
  the roadmap may decide adoption priorities, but doing them is a
  separate effort.
- Upstreaming work to ghostty-org/ghostty (AGENTS.md forbids it).
