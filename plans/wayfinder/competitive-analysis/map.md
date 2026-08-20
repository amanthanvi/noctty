# Noctty Competitive Analysis Map

Wayfinder map (`wayfinder:map`). Tracker: local markdown (AGENTS.md
directs agents not to create GitHub issues unprompted; the roadmap's
implementation issues were later opened at the user's explicit
request). Tickets are files in
[`tickets/`](tickets/); a ticket is claimed by filling its `Assignee`
field, closed by setting `Status: closed` and appending a
`## Resolution` section. A ticket is unblocked when every ticket in its
`Blocked-by` list is closed. Research reports land in
[`research/`](research/).

## Destination

**Reached 2026-08-19.** The roadmap is committed at
[`plans/2026-competitive-roadmap.md`](../../2026-competitive-roadmap.md)
and the adopted PRODUCT.md amendments are applied. All 16 tickets are
closed; this map is complete and now serves as the effort's record.

Original destination: a decided, prioritized competitive-response
roadmap committed to this repo — for each competitor strength,
weakness, or blind spot the analysis surfaces, an explicit
adopt / reject / defer decision with rationale, ready to hand to
`/implement`. The analysis report is an input, not the deliverable.

## Notes

- Domain: Windows terminal emulators. Noctty is a Windows-only hard
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
  aggregate; each dive ends with an explicit "Lessons for noctty"
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
- [Deep dive: wintty](tickets/R01-wintty.md) — direct rival ships broad
  native surface fast (WinUI3/DX12 soft fork) but has zero releases,
  no CI, sponsor-gated signing, bus factor 1; adopt its ConPTY
  workarounds + measurement culture, exploit installability/ARM64 lead.
- [Deep dive: Windows Terminal](tickets/R02-windows-terminal.md) —
  incumbent slowing; fixed folklore problems but stuck on cold start,
  ~2x input latency, settings sprawl, text-only restore, zero
  extensibility — the exploitable space is exactly PRODUCT.md's thesis.
- [Deep dive: WezTerm](tickets/R03-wezterm.md) — strongest power-user
  rival via Lua scripting + multiplexing domains, but Windows is a port
  (startup stalls, no ARM64) and no stable release since 2024-02.
- [Deep dive: Warp on Windows](tickets/R04-warp.md) — $73M
  agentic-terminal category-definer; steal workflow objects (quake,
  named layouts, restored scrollback), loudly reject cloud coupling,
  telemetry, forced updates.
- [Deep dive: Alacritty](tickets/R05-alacritty.md) — minimal-fast
  benchmark whose speed is no longer unique; tier-2 on Windows
  (unsigned, no ARM64, "use tmux" fails natively) — leaves noctty's
  benchmark user unserved.
- [Deep dive: Tabby](tickets/R06-tabby.md) — proves Windows devs pay a
  huge Electron tax for SSH/serial connection management, secrets
  vault, GUI settings; noctty can deliver that value natively.
- [Deep dive: ConEmu / Cmder](tickets/R07-conemu.md) — invented
  affordances no successor matched (elevated tabs, task system, OSC
  9;4); architecture became its ceiling; Cmder proves
  defaults/packaging multiply distribution.
- [Deep dive: Rio](tickets/R08-rio.md) — fastest-moving adjacent
  competitor (all three image protocols, real Windows distribution) but
  no session restore/profiles/WSL story; monitor, not threat.
- [Deep dive: upstream Ghostty parity](tickets/R09-upstream-ghostty.md)
  — core synced to 1.3.2-dev; real delta is ~5 months of main + the 1.4
  wave and libghostty shift; Windows GUI "still not planned" → 12–24
  month window as the definitive Ghostty-on-Windows.
- [Field sweep: long-tail](tickets/R10-long-tail.md) — no head-on rival,
  but: community ghostty-windows ports contest the exact niche,
  category drifts toward infrastructure workspaces, and Contour/
  Extraterm/mintty donate ideas. Promoted Wave Terminal and the
  ghostty-windows fork family to full dives.
- [Deep dive: Wave Terminal](tickets/R11-wave-terminal.md) — the
  workspace-drift flagship validates noctty's terminal-first frame:
  users beg it to be more terminal; development stalled (founder silent
  since 2026-05-10). Adopt durable sessions, scriptability, quake mode;
  exploit Electron/VT/keybinding weaknesses.
- [Deep dive: ghostty-windows community fork family](tickets/R12-ghostty-windows-forks.md)
  — the fork swarm is decaying and none out-tracks noctty; the real
  contest is upstream itself (Windows CI, Apr 2026 tier plan,
  libghostty). Live finding: upstream maintainer says unaffiliated
  projects must not use "Ghostty" in branding, naming noctty
  specifically — rename risk is a decision item.
- [Synthesis: ranked gap list](tickets/S01-synthesis.md) — 37 candidates
  (26 provisional adopts, 11 defers), 9 PRODUCT.md frame challenges, 11
  staged rejects, ranked in
  [research/synthesis.md](research/synthesis.md). Code check: status.md
  undersells shipped features (quick terminal, toasts, taskbar
  progress, docked search all exist) — six claimed gaps deduped into
  one docs-accuracy item. Decision-first: naming/trademark (F1),
  upstream-relations posture (F2).
- [Decision session: adopt/reject/defer](tickets/D01-decision-session.md)
  — every item ruled with the user (2026-08-19): all 26 adopts
  confirmed, all 11 defers ratified, all 11 rejects ratified
  individually. Frame: F1 naming = wait-and-see; F2 = hard fork, no
  upstreaming, deliberate downstream merges; F3 AI stance = silent; F4
  perf budgets, F5 launch topology, F6 session tiers + durability
  aspiration, F8 narrow SSH extension = adopted; F7 sustainability =
  skipped; C27 trust page = full send under the current name. Roadmap:
  three waves (credibility → moats → depth) in
  `plans/2026-competitive-roadmap.md`. C16 spike spawned as
  [Spike: durable-session feasibility](tickets/R13-durable-session-spike.md).
- [Spike: durable-session feasibility](tickets/R13-durable-session-spike.md)
  — verdict: **feasible-with-broker** (HPCON dies with its owner; a
  session-host process + named-pipe attach is proven art — VS Code pty
  host, WT #20077). XL confirmed for the full feature but known
  engineering, not research risk; smallest testable increment is an
  M-sized standalone `conpty-host` exe. Funding that increment is a
  roadmap decision for the assembly ticket.
- [Assemble the competitive roadmap](tickets/T01-assemble-roadmap.md)
  — the destination: `plans/2026-competitive-roadmap.md` committed
  (three waves, 26 adopts + conpty-host increment, 11 non-goals,
  deferred ledger) and the four PRODUCT.md amendments applied.
  Assembly-time rulings: conpty-host scheduled in Wave 2 after
  scrollback restore; F4 budgets carry provisional targets until the
  benchmark suite's first baseline.

## Not yet specified

<!-- in-scope fog; graduates into tickets as the frontier advances -->

None — the frontier reached the destination. Follow-on work lives in
[`plans/2026-competitive-roadmap.md`](../../2026-competitive-roadmap.md),
not on this map.

## Out of scope

<!-- ruled beyond the destination; never graduates -->

- Hands-on evaluation of competitors on a real Windows machine —
  consciously ruled out at charting; all claims stay research-sourced.
- Implementing any roadmap item — this map ends when decisions are made.
- Marketing/community _execution_ (writing posts, running outreach);
  the roadmap may decide adoption priorities, but doing them is a
  separate effort.
- Upstreaming work to ghostty-org/ghostty (AGENTS.md forbids it).
