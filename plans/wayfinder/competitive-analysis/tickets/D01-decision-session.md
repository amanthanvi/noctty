# Decision session: adopt/reject/defer

- Label: wayfinder:grilling
- Status: closed
- Assignee: decision session with the user, 2026-08-19
- Blocked-by: S01

## Question

For each candidate in the synthesis's ranked list, what is the ruling —
adopt, reject, or defer, with rationale? HITL batch-grilling session
(`/batch-grill-me`) walking the ranked list with the user; the user
rules, the agent argues the evidence. Items too big or contentious to
settle in the batch spawn individual grilling tickets (graduating fog on
the map). PRODUCT.md-amendment candidates get explicit rulings too.
Resolution records every ruling; the roadmap is assembled from them in
the next ticket, not here.

## Resolution

Resolved 2026-08-19 in a live batch-grilling session with the user.
Every synthesis item was walked — rejects individually, adopts by
theme, frame challenges one by one. The complete ruling record:

### Frame challenges

- **F1 Naming/trademark: WAIT AND SEE.** No rename, no permission
  request, no branding freeze. Ruled against the synthesis
  recommendation; rename risk consciously accepted.
- **F2 Upstream posture: hard fork, no upstreaming.** In the user's
  words: "We don't gunk up the upstream Ghostty repo but are open to
  adopting and adapting upstream changes to our downstream as
  feasible." AGENTS.md's no-upstreaming rule stands; C33's deliberate
  merge cadence is the mechanism.
- **F3 AI/agent stance: STAY SILENT.** No PRODUCT.md text; R2 still
  governs internally.
- **F4 Performance budgets: ADOPT.** PRODUCT.md gains explicit budgets
  (cold-start-to-first-frame, key-to-pixel latency, memory/pane, idle
  power); C01 enforces them in CI.
- **F5 Launch topology: ADOPT.** OS entry-points principle added to
  PRODUCT.md, housing C11–C14.
- **F6 Session promise: ADOPT TIERS + ASPIRATION.** Layout (shipped) →
  content (C15) → process durability as a named aspiration gated on
  the C16 feasibility spike.
- **F7 Sustainability statement: SKIP.** No amendment.
- **F8 Remote scope: EXTEND NARROWLY.** Benchmark user gains "…and the
  remote hosts they reach over SSH"; lean C20 only; bundled clients,
  vaults, and fleet tools stay out.
- **F9 Published non-goals: SATISFIED VIA C27** (full send).

### Rejects — all 11 ratified (walked individually)

R1 cloud coupling/accounts/telemetry · R2 AI-first pivot (internal
rule; public silence per F3) · R3 breadth-before-performance (an
ordering rule tied to C01's gates) · R4 Electron/framework
re-platforming · R5 workspace drift (the keyboard-first file-preview
idea is parked as a note, not a carve-out) · R6 forced/silent
auto-update · R7 plugin runtime + hosted sync (C25 is the sanctioned
alternative) · R8 DLL injection/hooks · R9 daily-rebase soft-fork
conversion · R10 shell-editor interception / proprietary output
protocol · R11 chrome-only differentiation.

### Adopts — all 26 confirmed (walked by theme)

- A+B: C01 benchmark suite + CI gates, C02 power/battery, C03
  GPU-floor doc + graceful-fail S slice only (fallback renderer stays
  deferred), C04 status.md accuracy (ordered first).
- C: C05 bundled newer OpenConsole conpty.dll + degraded-mode logging
  + mangling catalog, C06 UTF-8 preamble with CJK guard, C07 cmd.exe
  OSC 133 via PROMPT + optional Clink, C08 1.3-surface Win32 wiring
  audit.
- D: C11 default-terminal registration, C12 jump lists, C13 Explorer
  context menu, C14 elevation model + elevated-window action
  (mixed-elevation tabs out).
- E: C15 scrollback-content restore, C17 named layouts, C18
  quick-select/hints + copy mode, C19 prompt-mark navigation verbs,
  C20 lean SSH ingestion.
- F: C25 documented CLI automation surface, staged — verb design waits
  for upstream 1.4's scriptability shape.
- G: C27 identity/trust page FULL SEND under the current name
  (rename-risk accepted; publishes the ratified non-goals → F9), C28
  SmartScreen/signing reputation, C29 portable mode + ZIP updater
  apply, C30 Chocolatey, C31 GitHub-coupling contingency.
- H: C32 paste-path audit now + incremental fuzzing, C33 upstream
  merge cadence + published merge policy (the F2 mechanism).
- I: C34 accessibility — finish UIA, per-release screen-reader matrix.

### Defers — all 11 ratified

C09 sixel/iTerm2 images (after C05) · C10 WSL VSOCK bypass (keepalive
slice opportunistic) · C16 durable local sessions (feasibility spike
spawned as [Spike: durable-session feasibility](R13-durable-session-spike.md))
· C21 snippets · C22 broadcast input · C23 vertical tabs · C24 secrets
vault · C26 config portability stance · C35 D3D11 renderer · C36
localization · C37 serial/COM.

### Roadmap mechanics (binding on T01)

`plans/2026-competitive-roadmap.md`, three waves: **Wave 1
"credibility"** — C04, C01, C03-S, C32-audit, C06, C07, C12, C13, C19;
**Wave 2 "moats"** — C05, C11, C15, C17, C02, C08, C14, C28–C31,
C33-recurring; **Wave 3 "depth"** — C18, C20, C25-staged, C34,
C27-full-page. Each entry carries its ruling, rationale, and evidence
links, ready for /implement. T01 also applies the adopted PRODUCT.md
amendments (F4, F5, F6, F8). No items were contentious enough to spawn
individual grilling tickets.
