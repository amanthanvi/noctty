# 2026 Competitive Roadmap

The decided, prioritized competitive-response roadmap for noctty,
assembled 2026-08-19 from the competitive-analysis wayfinder effort:
twelve research deep-dives, a cross-referenced synthesis, and a full
adopt/reject/defer decision session. Every entry below carries an
explicit ruling. The rulings are final; some implementation targets remain staged or provisional where noted inline (the performance budgets, C25's design gate, the conpty-host feasibility increment).

- Judging frame: [PRODUCT.md](../PRODUCT.md) (as amended by this
  effort: performance budgets, launch topology, session tiers, narrow
  SSH scope).
- Sources: [map](wayfinder/competitive-analysis/map.md) ·
  [synthesis](wayfinder/competitive-analysis/research/synthesis.md)
  (candidate IDs C01–C37 and full evidence citations) ·
  [decision session ruling record](wayfinder/competitive-analysis/tickets/D01-decision-session.md)
  · twelve reports in
  [research/](wayfinder/competitive-analysis/research/): wintty,
  Windows Terminal, WezTerm, Warp, Alacritty, Tabby, ConEmu/Cmder,
  Rio, upstream Ghostty, long-tail sweep, Wave Terminal,
  ghostty-windows forks, plus the durable-session spike.
- Cost classes: S ≲ days · M ≲ weeks · L ≈ month+ · XL ≈ quarter+.
- Tracker: each work item is a GitHub issue on this fork
  ([#120–#146](https://github.com/amanthanvi/noctty/issues?q=label%3Aroadmap),
  labels `roadmap` + `wave-1/2/3`), linked from its heading below. The wayfinder map's own process tickets remain closed local-markdown records of the completed analysis; GitHub issues are the sole tracker for this roadmap's implementation work.

## Strategy rulings (binding context)

- **Naming:** wait and see. No rename, no permission request, no
  branding freeze. The trademark statement by an upstream collaborator
  (2026-07-12, ghostty-org discussion #12371, naming noctty) is a
  known, accepted risk.
- **Upstream posture:** hard fork. No upstreaming ("we don't gunk up
  the upstream Ghostty repo"); open to adopting and adapting upstream
  changes downstream as feasible. The merge-cadence entry (Wave 2)
  is the standing mechanism.
- **AI stance:** public silence. No PRODUCT.md text; the AI-first-pivot
  non-goal below governs internally.
- **Sustainability statement:** skipped; no PRODUCT.md text.

## Published non-goals

Eleven ratified rejects, each backed by a competitor's documented
failure. These are standing scope rules and the source text for the
identity/trust page (Wave 3).

1. **No cloud coupling** — no accounts, telemetry, or hosted services.
   Warp's login/telemetry history remains its dominant trust complaint;
   Wave gated BYOK AI on telemetry consent; Tabby's sync service died
   and stranded users. Local-only (ADR-0004) is a marketed asset.
2. **No AI-first pivot or bundled chatbot.** Warp's fundamentals lagged
   its AI runway; Wave's AI roadmap crowded out rebindable keys and a
   palette. Internal rule; public posture stays silent.
3. **No feature breadth before performance/reliability** — an ordering
   rule tied to the benchmark suite's CI gates. Observed failure three
   times: wintty (backdrops before scroll performance), Windows
   Terminal (flagship features crashing for months), Rio
   (ship-then-stabilize churn).
4. **No re-platforming onto Electron or fashionable UI frameworks.**
   Tabby/Wave/Hyper show the permanent Electron floor; Fluent died on
   UWP; wintty's own maintainer spec'd a no-.NET escape hatch citing
   CLR/GC costs. Zig + raw Win32 is validated from inside the rival
   camp.
5. **No workspace/widget drift** — no embedded browsers, DB clients,
   file managers. Wave's users beg it to be more terminal. (Parked
   note, not a carve-out: keyboard-first file _preview_ via the
   already-shipped Kitty graphics was Wave's most-praised non-AI
   feature; a future discussion may revisit it.)
6. **No forced or silent auto-update.** Warp's top operational
   complaint. Updates stay user-initiated, checksum + Authenticode
   verified, staged.
7. **No in-process plugin runtime or hosted sync.** Tabby's plugin
   surface multiplied memory, CVEs, and abandonment; Hyper's ecosystem
   hollowed out. The automation surface (Wave 3) is the sanctioned
   alternative: script the terminal from outside.
8. **No DLL injection or undocumented hooks.** ConEmu's decade of AV
   quarantines and hook conflicts; everything it hooked for is now
   reachable via ConPTY + documented APIs.
9. **No daily-rebase soft-fork conversion.** wintty's force-pushed
   branches and rewritten SHAs are contributor-hostile and
   release-hostile; deliberate scheduled merges are the middle path.
10. **No shell-editor interception or proprietary output protocol.**
    Warp's input-editor takeover breaks fzf/Starship/PSReadLine muscle
    memory. The shell's editor is sacred; "your prompt tools just
    work" is a positioning line.
11. **No chrome-only differentiation.** Fluent Terminal died the day
    the platform vendor shipped a competent default. Depth — VT
    correctness, fluidity, sessions, trust — is the only defensible
    ground.

## Wave 1 — Credibility

Small items that compound: they re-baseline the docs, make the
performance claim falsifiable, and take the cheap OS entry points.
Order within the wave: C04 first (it corrects the record everything
else builds on), then C01; the rest are parallelizable.

### C04 · status.md and capability-matrix accuracy — S · [#120](https://github.com/amanthanvi/noctty/issues/120)

**Ruling:** adopt, first. **Why:** code verification found the docs
materially undersell the product — quick terminal with global hotkey
(`src/apprt/win32_quick_terminal.zig`), WinRT toasts
(`win32_toast_winrt.zig`), taskbar progress
(`win32_taskbar_progress.zig`), and docked scrollback search
(`win32_search_bar.zig`) all ship today and appear nowhere in
[docs/status.md](../docs/status.md) or the capability matrix. Six of
twelve competitor reports independently mis-listed these as gaps; users
will be misled identically. **Shape:** audit `src/apprt/` module by
module against status.md and
[docs/windows-capability-matrix.md](../docs/windows-capability-matrix.md);
add the missing rows (also check status bar, link preview, paste
protection); refresh the "last updated" contract. Evidence: synthesis
ground-truth note; wintty report §10.

### C01 · Published, reproducible Windows benchmark suite + CI perf gates — M · [#121](https://github.com/amanthanvi/noctty/issues/121)

**Ruling:** adopt. **Why:** "fastest, most fluid" is the product's
entire thesis and no terminal in the field publishes credible Windows
numbers — Windows Terminal's ~2× conhost latency is documented by third
parties (chadaustin.me) while its own numbers are absent; Alacritty's
vtebench culture proves perf-as-artifact works; wintty wrote the full
metric plan but never executed it — publishing first converts their
plan into our marketing. **Shape:** vtebench-style throughput harness
plus Windows-specific metrics — cold-start-to-first-frame, key-to-pixel
latency (camera/photodiode methodology documented), ConPTY round-trip,
scroll MB/s, frame-time p95, steady-state memory per pane, idle
GPU/CPU — run same-machine against Windows Terminal, Alacritty, Tabby,
Wave; publish results in docs; wire regression gates into CI against the PRODUCT.md budgets (provisional until this suite's first baseline fixes them; CI gates the software-reproducible metrics, while camera/photodiode key-to-pixel latency is a scheduled lab measurement with a documented CI proxy). Evidence: synthesis C01; alacritty §10.1, wintty §2/§10.9,
wt §2/§10, rio §10.6, tabby §10.1, wave §10.2.

### C03 · GPU floor documentation + graceful degraded-mode — S · [#122](https://github.com/amanthanvi/noctty/issues/122)

**Ruling:** adopt the S slice only; any fallback renderer stays
deferred. **Why:** corporate/VM/RDP machines are normal Windows dev
environments; a terminal that won't start there violates "always leave
a path back to a working terminal." **Shape:** document the OpenGL
4.3+ requirement and behavior below it (RDP, VMs, old iGPUs); fail
with a visible, actionable message instead of a blank window. Evidence:
synthesis C03; alacritty §10.4, warp §2, wez §2, wt §2.

### C32 · Win32 paste-path security audit (fuzzing follows incrementally) — S audit, M fuzzing · [#123](https://github.com/amanthanvi/noctty/issues/123)

**Ruling:** adopt; audit immediately. **Why:** upstream's
CVE-2026-26982 paste-sanitization fix was verified on upstream's
surface — the fork's own Win32 clipboard/drag-drop paths have none of
the core's AFL++ coverage; Rio shipped a hint-URL command-execution
vuln on Windows; this is "reliability as a feature" due diligence.
**Shape:** one-time audit that the CVE fix covers
`src/apprt/win32.zig` clipboard/drag-drop ingestion; then incremental
fuzzing of fork-only surfaces (paste paths, ConPTY I/O, session-state
JSON, IPC) reusing upstream's corpus approach. Evidence: synthesis
C32; up §6/§10.1, rio §6, tabby §6.

### C06 · UTF-8 console preamble with CJK code-page guard — S · [#124](https://github.com/amanthanvi/noctty/issues/124)

**Ruling:** adopt. **Why:** Nerd-Font/oh-my-posh mojibake in
cmd/PowerShell 5.1 is a first-session failure for exactly the
PowerShell-first benchmark user; wintty ships the complete tested
design to copy. **Shape:** `chcp 65001` for cmd,
`[Console]::OutputEncoding` for PowerShell, behind
`utf8-console = auto|always|never` with a guard refusing auto-forcing
on legacy CJK ANSI code pages. Evidence: synthesis C06; wintty
§3/§10.2.

### C07 · cmd.exe shell integration via PROMPT + optional Clink — S · [#125](https://github.com/amanthanvi/noctty/issues/125)

**Ruling:** adopt. **Why:** closes the last unsupported-shell gap
(status.md: cmd is a "plain fallback"); cwd-correct restore and
prompt-jump then work in cmd; Warp doesn't support cmd at all.
**Shape:** emit OSC 133;A/B and OSC 9;9 (cwd) from the `PROMPT`
environment variable; auto-load a Clink lua for 133;C/D + exit codes
when Clink is present; degrade gracefully without it. Evidence:
synthesis C07; wintty §4/§10.3.

### C12 · Taskbar jump lists — S · [#126](https://github.com/amanthanvi/noctty/issues/126)

**Ruling:** adopt. **Why:** taskbar re-entry into a recent directory
or pinned profile is core native feel for a user who pins the
terminal; wintty ships it, ConEmu proved it for a decade; verified
absent (no `ICustomDestinationList` usage). **Shape:**
`ICustomDestinationList` with recent directories (from OSC 9;9/shell
integration) + pinned profiles; extend with named layouts once C17
lands. Evidence: synthesis C12; wintty §3/§10.4, conemu §3/§10.4.

### C13 · Explorer "Open noctty here" context menu — S · [#127](https://github.com/amanthanvi/noctty/issues/127)

**Ruling:** adopt. **Why:** cheapest expected OS entry point; even
minimal Alacritty ships it; Tabby users fight registry hacks for it.
**Shape:** classic registry entries + Win11 `IExplorerCommand` for
directory and directory-background; registration via the installer (portable-mode registration follows C29's portable work in Wave 2). Evidence: synthesis C13; alacritty §3, conemu,
tabby §3.

### C19 · Prompt-mark navigation verbs, surfaced — S · [#128](https://github.com/amanthanvi/noctty/issues/128)

**Ruling:** adopt. **Why:** converts already-shipped OSC 133 shell
integration (including PowerShell) into felt daily value —
jump-to-previous/next command, copy-last-command-output,
re-run-last-command — "80% of Warp-blocks value at 0% of the
ConPTY-fork cost," without touching the shell's editor (non-goal 10).
**Shape:** palette actions + default keybinds over existing prompt
marks; document as part of shell-integration docs. Evidence: synthesis
C19; warp §10.4, rio §10.5, lt §a.3, wt §4.

## Wave 2 — Moats

The differentiators no Windows-native rival has: owned ConPTY,
default-terminal capture, deep sessions, and the trust/distribution
lead extended.

### C05 · Own the ConPTY layer: bundled OpenConsole + degraded-mode logging + mangling catalog — M · [#129](https://github.com/amanthanvi/noctty/issues/129)

**Ruling:** adopt. **Why:** the flagship capability claim (Kitty
graphics, deep VT) currently depends on whatever conhost version the
user's OS carries — the in-box `CreatePseudoConsole`
(`src/pty.zig:430`) silently strips Kitty APC/Sixel on older builds
(wintty measured it; Warp forked ConPTY over it). The single biggest
silent-failure risk in the product's core promise. **Shape:** ship the redistributable ConPTY pair (`conpty.dll` + matching-architecture `OpenConsole.exe`) beside the exe and load `CreatePseudoConsole` explicitly from the bundled DLL — the current `kernel32` import would ignore a side-by-side DLL — falling back to the in-box `kernel32`/conhost path with a loud logged warning naming what degrades; publish a
ConPTY-mangling/mitigation catalog + measured esctest baseline
extending [docs/windows-vt-conformance.md](../docs/windows-vt-conformance.md).
Evidence: synthesis C05; wintty §3/§10.1/§10.5, rio §3/§10.1, warp §3,
wt §3, forks (ghostinthewsl).

### C11 · Default-terminal registration (`ITerminalHandoff`) — M · [#130](https://github.com/amanthanvi/noctty/issues/130)

**Ruling:** adopt. **Why:** how a terminal becomes _the_ terminal —
captures consoles the user didn't explicitly launch (Explorer, IDEs).
Only Windows Terminal has it; every rival has an open unfulfilled
issue (Alacritty #6036, WezTerm #7534, Warp #6261, Tabby #4882);
first-mover slot among non-Microsoft terminals. **Shape:** COM
registration + `ITerminalHandoff` implementation routing handed-off
consoles into a new tab/window; handle elevation and multi-instance
policy; register from installer and settings. Evidence: synthesis C11;
wt §3, conemu §3, wintty §3.

### C15 · Scrollback-content restore — M · [#131](https://github.com/amanthanvi/noctty/issues/131)

**Ruling:** adopt. **Why:** session restore currently brings back layout and pane metadata but no scrollback content, so restored panes start blank; Windows Terminal ships buffer snapshots (with
instructive rollout bugs), Warp's restored blocks are a top retention
feature; noctty's transactional session machinery can do it
reliably — the second tier of the amended session promise. **Shape:**
optionally persist last-N lines per pane with `window-save-state`,
restored clearly marked as a snapshot; size/redaction knobs; crash-safe
write path reusing existing session-state transactions. Evidence:
synthesis C15; wt §5/§10.3, warp §5/§10.3, lt §a.1.

### conpty-host feasibility increment (from the durable-session spike) — M · [#132](https://github.com/amanthanvi/noctty/issues/132)

**Ruling:** scheduled here, after C15. **Why:** the spike verdict is
feasible-with-broker — an `HPCON` dies with its owning process, so
durability requires a session-host process owning ConPTYs + children
with named-pipe attach (proven art: VS Code's pty host, Windows
Terminal's #20077 proposal). This increment validates the third tier
of the session promise without committing the XL build. **Shape:**
standalone `conpty-host` exe reusing `src/pty.zig`/`Command.zig`:
owns one pwsh under ConPTY, ring-buffers output, serves a named pipe;
test = attach, run a TUI, hard-kill the client, reattach, confirm the
shell survived and the viewport repaints on a resize nudge. Green
graduates durable-session planning (C16); red caps the aspiration
honestly. Evidence:
[durable-session-spike report](wayfinder/competitive-analysis/research/durable-session-spike.md).
**Result (2026-08-21): GREEN; C16 may graduate to planning, while the
XL implementation remains deferred and unscheduled.**

### C17 · Named layouts: profile + split tree + hotkey in one object — M · [#133](https://github.com/amanthanvi/noctty/issues/133)

**Ruling:** adopt. **Why:** turns session restore from "what I had"
into "what I want" — project switching for the tabs-and-splits user;
ConEmu's signature system, Warp's launch configs, WezTerm's
workspaces; builds on session-persistence machinery that already
exists. **Shape:** named workspace definitions (commands, cwds, split
tree) materialized via keybind, palette entry, CLI flag, and (with
C12) jump-list click. Evidence: synthesis C17; conemu §5/§10.3, warp
§5/§10.2, wez §5.

### C02 · Power/battery awareness as a performance axis — M · [#134](https://github.com/amanthanvi/noctty/issues/134)

**Ruling:** adopt. **Why:** the benchmark user works on a laptop;
upstream structurally deprioritizes battery ("GPU or nothing"
complaint stream) — cheap differentiation against upstream and every
Electron rival; folds into C01's scoreboard as measured idle wattage.
**Shape:** power-saver detection with adaptive rendering,
unfocused-render throttling / target-fps knobs, occlusion-aware
repaint; publish idle power in the benchmark suite. Evidence:
synthesis C02; up §2/§9/§10.2, wintty §3/§10.8, rio §10.3.

### C08 · Ghostty 1.3-surface Win32 wiring audit — S · [#135](https://github.com/amanthanvi/noctty/issues/135)

**Ruling:** adopt. **Why:** inherited-on-paper features that silently
no-op on Windows are precisely the "generic parity fork" failure the
anti-references name; Kitty keyboard protocol is now table stakes (WT
1.25). **Shape:** one-time audit that 1.3 core features in the
1.3.2-dev baseline behave on Win32 — kitty keyboard on the Win32 input
path, `scrollbar`, notify-on-command-finish → the existing toast
pipeline, `key-remap`, clipboard-codepoint-map; record results in the
capability matrix. Evidence: synthesis C08; up §7/§10.6, wt §10.6.

### C14 · Elevation as a designed surface — M · [#136](https://github.com/amanthanvi/noctty/issues/136)

**Ruling:** adopt (documented model + elevated-window action);
mixed-elevation tabs are explicitly out. **Why:** the benchmark user
runs elevated shells weekly; an undesigned surface violates "be native
where behavior matters"; ConEmu's elevated tabs remain the unmatched
affordance, WT documents a deliberate separate-window model. **Shape:**
document what elevated noctty means (incl. what restore does with
elevated sessions); add a "run elevated" profile flag + palette action
opening a clearly-marked elevated window. Evidence: synthesis C14;
conemu §3/§10.1, wt §3/§10.8, wave §3.

### C28 · SmartScreen/signing reputation hardening — S/M · [#137](https://github.com/amanthanvi/noctty/issues/137)

**Ruling:** adopt. **Why:** the last trust gap in a
best-in-field distribution story; first-run SmartScreen warnings kill
installs; Alacritty is unsigned since 2021, ConEmu shows the AV
reputation death spiral. **Shape:** sign every release consistently (SignPath Foundation or equivalent) and build SmartScreen file-hash reputation over time — EV no longer grants instant reputation (Microsoft removed that privilege in 2024); sign or attest the portable ZIP container; document verification steps (feeds the trust page). Evidence:
synthesis C28; alacritty §3/§10.5, rio §3, conemu §9.

### C29 · Portable mode + portable-ZIP updater apply — M · [#138](https://github.com/amanthanvi/noctty/issues/138)

**Ruling:** adopt. **Why:** locked-down corporate machines are a
genuine persona of the benchmark user; WezTerm's thumb-drive mode and
Tabby's portable data dir prove demand; ZIP update-apply is already on
status.md's next list. **Shape:** config/state discovery beside the
exe; implement staged apply/rollback for the portable ZIP channel.
Evidence: synthesis C29; wez §3, tabby §3, lt (MobaXterm).

### C30 · Chocolatey channel — S · [#139](https://github.com/amanthanvi/noctty/issues/139)

**Ruling:** adopt. **Why:** enterprise fleets script choco; near-zero
recurring cost next to the existing winget/Scoop automation. **Shape:**
add a choco package to the release pipeline alongside winget/Scoop.
Evidence: synthesis C30; wave §10.7, rio §10.6.

### C31 · GitHub-coupling contingency — S · [#140](https://github.com/amanthanvi/noctty/issues/140)

**Ruling:** adopt. **Why:** upstream is leaving GitHub (destination
unannounced) and the fork's updater hardcodes `api.github.com` —
infrastructure upstream itself just judged unreliable. **Shape:**
abstract the updater endpoint; monitor upstream mirror freshness; keep
sync tooling re-pointable. Evidence: synthesis C31; up §1/§10.5.

### C33 · Upstream merge cadence + published merge policy — S/M recurring · [#141](https://github.com/amanthanvi/noctty/issues/141)

**Ruling:** adopt — this is the standing mechanism of the hard-fork
posture. **Why:** the moat is priced in merge labor; deferring
compounds, and the Sept 2026 1.4 wave (scriptability, tmux-control
GUI, graphical preferences) collides with the fork's own settings
window and palette if absorbed as one conflict bomb; visible merge
cadence is also a trust signal (frozen forks decay publicly).
**Shape:** merge upstream main incrementally now (kitty key-release,
UTF-8/VT fixes, renderer work); document the drift/merge policy in
docs. Evidence: synthesis C33; up §10.2, forks §10, wintty §1.

## Wave 3 — Depth

### C18 · Quick-select / hints + modal copy mode — M · [#142](https://github.com/amanthanvi/noctty/issues/142)

**Ruling:** adopt. **Why:** pure keyboard-first territory (principle 2) with no current implementation beyond URL hover-hints — regex
capture of URLs/paths/hashes/IPs to open/copy/paste, plus modal
keyboard selection and scrollback navigation; Alacritty's hints + vi
mode are the polished reference. **Shape:** hint overlay + actions;
modal copy mode with vi-style motions; configurable patterns.
Evidence: synthesis C18; alacritty §4/§10.2–3, wez §5/§10.3, rio
§4/§10.4, lt §a.4.

### C20 · Lean SSH host ingestion — M · [#143](https://github.com/amanthanvi/noctty/issues/143)

**Ruling:** adopt (lean slice only, per the amended user scope).
**Why:** the benchmark user's week includes remote hosts (Tabby's 74k
stars are built on connection management; WezTerm auto-populates SSH
domains); discovery is the missing piece — noctty already wraps
ssh for terminfo. **Shape:** parse `%USERPROFILE%\.ssh\config`,
surface hosts as launchable profiles/palette entries running the
system `ssh`; no bundled client, no vault (deferred), no fleet tools
(out). Evidence: synthesis C20; tabby §5/§10.1, wez §5/§10.5, wt §3.

### C25 · Documented automation surface (CLI verb set) — L, staged · [#144](https://github.com/amanthanvi/noctty/issues/144)

**Ruling:** adopt, staged — verb design waits until upstream 1.4's
scriptability shape is visible (via C33 merges), so nothing is
designed twice. **Why:** lets keyboard-first users and their scripts
drive the terminal and lets users self-serve missing features — the
decade-old extensibility vacuum Windows Terminal never filled — while
staying outside the process (non-goal 7). **Shape:** grow
`+list-windows` / allowlisted `+perform-action` into a stable,
documented, PowerShell-friendly verb set (open/split/launch
profile/query state/run named layout); align with upstream's contract
where sensible. Evidence: synthesis C25; wez §7/§10.2, wt §7/§10.6,
conemu §7, wave §10.3, up §10.4.

### C34 · Accessibility: finish UIA, publish a screen-reader matrix — M · [#145](https://github.com/amanthanvi/noctty/issues/145)

**Ruling:** adopt. **Why:** the entire competitive field ignores
accessibility (one rival fork admits screen readers can't read its
panes); noctty's partial UIA work is unique — worth finishing and
stating; aligns with the existing WCAG commitment. **Shape:** complete
the UIA work already on status.md's next list; publish a per-release
Narrator/NVDA/JAWS compatibility matrix; state it on the trust page.
Evidence: synthesis C34; forks §10.

### C27 · Identity, trust, and verification page + migration guides — S · [#146](https://github.com/amanthanvi/noctty/issues/146)

**Ruling:** adopt — full send under the current name (rename risk
accepted with eyes open). **Why:** every distribution advantage
noctty already has — signed releases, winget/Scoop, ARM64, CI,
session restore — is unmarketed; fork confusion is documented in
upstream's own threads; trust is the moat the swarm can't cross.
**Shape:** a "why noctty / how we differ from the fork field / how
to verify our binaries (signing, checksums) / what we will never do"
page publishing the eleven non-goals; "migrate from Windows Terminal"
and "migrate from Git Bash/mintty" guides; visible release cadence.
Evidence: synthesis C27; forks §9/§10, wintty §10.1, warp §8/§10.5,
lt.

## Deferred ledger

Ratified defers, each with its revisit condition.

| ID  | Item                              | Revisit when                                                                     |
| --- | --------------------------------- | -------------------------------------------------------------------------------- |
| C09 | Sixel + iTerm2 inline images      | After C05 lands; on user demand (WSL legacy tooling)                             |
| C10 | WSL VSOCK PTY bypass              | If C05 leaves WSL VT gaps; keepalive slice may land opportunistically any time   |
| C16 | Durable local sessions (XL build) | On a green conpty-host increment (Wave 2); ceiling per spike: logon-session only |
| C21 | Snippets / saved-commands library | On demand signal; palette provider model keeps it cheap later                    |
| C22 | Broadcast input                   | On demand signal                                                                 |
| C23 | Vertical/side-docked tabs         | On demand signal; must survive the chrome-justification bar                      |
| C24 | Secrets via Credential Manager    | Only after C20 proves the SSH slice                                              |
| C26 | Config portability stance         | Write the stance when convenient; never a sync service (non-goal 1/7)            |
| C35 | D3D11 renderer option             | If C01 data or the ARB migration surfaces OpenGL-specific pain                   |
| C36 | Localization stance               | Post-roadmap; IME already covers input                                           |
| C37 | Serial/COM workflows              | Likely answered as a stated non-goal on the trust page instead                   |

## Sequencing notes

- Wave 1's C04 precedes everything (it corrects the record); C01
  precedes any marketing claim of speed.
- Ordering rule (non-goal 3): new features must not regress the C01
  gates once active.
- C05 precedes C09 reconsideration; C15 precedes the conpty-host
  increment; C20 precedes any C24 reconsideration; C33 runs
  continuously and gates C25's design start.
- C27 publishes last in Wave 3 so it can cite shipped benchmarks
  (C01), signing posture (C28), and the accessibility matrix (C34).
