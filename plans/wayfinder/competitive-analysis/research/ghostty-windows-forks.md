# Deep dive: the community ghostty-on-Windows fork family

Research date: 2026-08-17. Family-level dive promoted from the
[long-tail sweep](long-tail.md); rubric sections adapted where a
per-product frame does not fit a ten-project field.

## Executive summary

The "adilahmeddev lineage" the sweep flagged is real but decaying — the
root fork is deleted/private, one AI-era port is already archived, and
no hard fork out-tracks winghostty (255★) on stars, releases, signing,
or packaging. The live threat is not any fork: it is upstream itself —
Windows CI, a tiered contribution plan, mattn actively working Tier 2,
wintty's 17 merged PRs, and mitchellh's bet that libghostty consumers
dwarf the GUI by mid-2027. Ghostty maintainer pluiedev stated (Jul 12,
2026, prompted by a question about winghostty) that unaffiliated
projects **must not use "Ghostty" in their branding** — a live
rename/trademark risk for winghostty itself. Strategic conclusion:
winghostty wins the fork field today on trust and completeness, but
"THE Ghostty on Windows" title will be claimed by upstream or a blessed
libghostty consumer, so winghostty should position as its own product,
prepare a naming posture, and exploit the field's unverifiable-AI-claims
problem with signed, verified, benchmarked releases.

## 1. Identity & strategy (family map)

Four architectural archetypes, ordered by threat relevance:

**A. Hard forks with a Win32 apprt (winghostty's own archetype):**

- **adilahmeddev `windows-apprt` lineage (root: gone).**
  `github.com/adilahmeddev/ghostty` and `/ghostty-windows` both return
  404 and no ghostty repo appears in the user's 44-repo listing
  ([profile](https://github.com/adilahmeddev?tab=repositories)) —
  deleted or made private (uncertain which). The ~34,337 lines of
  Windows code (Win32 runtime, DirectWrite, **D3D11-primary renderer
  with OpenGL fallback**, GDI overlays) survive only as snapshots in
  downstream repos.
- **[Thr45hx/ghostty-windows](https://github.com/Thr45hx/ghostty-windows)**
  — 59★/8 forks, the family's most-starred hard fork. A build-and-
  package effort on top of the adilahmeddev branch, explicitly
  AI-driven ("asked Claude to build Ghostty natively on Windows" per its
  own docs), 12 build attempts over 2026-03-14/15, self-described
  "stable for daily use," disclosed to mitchellh (self-reported)
  ([BUILD-LOG](https://github.com/Thr45hx/ghostty-windows/blob/master/BUILD-LOG.md)).
  One release (`v1.3.0-dev-windows`, Mar 26, updated Jul 1 2026 with
  AVX-512-crash and installer-PATH fixes), Inno Setup installer
  requiring admin, SHA-256 checksum, **no code signing**
  ([releases](https://github.com/Thr45hx/ghostty-windows/releases)).
  Only 16 commits; "passion project / proof-of-concept" with stated
  uncertain maintenance.
- **[shiweis/ghostty-windows](https://github.com/shiweis/ghostty-windows)**
  (formerly InsipidPoint) — 38★/5. The most technically active hard
  fork: OpenGL 4.6/WGL renderer, ConPTY, tabs/splits with drag-resize,
  quick terminal (global-hotkey slide-in), command palette, IME, OSC 52
  authorization, desktop notifications, claims "feature-complete, 66/66
  apprt actions" and 25+ PowerShell/WSL2 automated tests. **Actively
  merges upstream main** (e.g. "Merge upstream ghostty-org/ghostty main
  (261 commits)" Jul 26, 2026) with commits co-authored by "claude"
  ([commits](https://github.com/shiweis/ghostty-windows/commits/main)).
  **No releases — build-from-source only** (Zig 0.16,
  `-Dapp-runtime=win32`). Claims unverifiable without artifacts.
- **[zcg/ghostty-win](https://github.com/zcg/ghostty-win)** — 27★,
  Direct2D-primary/D3D11-alternative renderers, Mica/Acrylic title
  bars, ConPTY. **Archived 2026-08-11** with a candid Chinese README
  note: created "during the GPT-5.4 era," no longer maintained. The
  family's first confessed AI-era abandonment.
- **[WolftacDigital/Spectre](https://github.com/WolftacDigital/Spectre)**
  — 0★, fork of InsipidPoint's tree, notable only because it **already
  renamed away from "ghostty-windows"** (trademark compliance),
  last active Jun 2026.
- Mirror layer: [qianhaoq](https://github.com/qianhaoq/ghostty-windows),
  [liamsmith86](https://github.com/liamsmith86/ghostty-windows) (1★
  each, stale since Apr 2026) — the "near-identical clones" the sweep
  saw; no independent development evidence.

**B. libghostty consumers (not forks — upstream's preferred shape):**

- **[marler8997/mite](https://github.com/marler8997/mite)** — 22★.
  "Native terminal emulator with libghostty at its core"; on Windows
  D3D11 + DirectWrite, **<2 MB exe**. Author is the credible one: he
  submitted upstream's original
  [Native Win32 App Runtime PR #1519](https://github.com/ghostty-org/ghostty/pull/1519).
  But only 11 commits, **idle since 2026-05-17**
  ([commits](https://github.com/marler8997/mite/commits/master));
  [missdeer's fork](https://github.com/missdeer/mite) adds tabs/fonts.
- **[sudo-tee/hollow](https://github.com/sudo-tee/hollow)** — 22★, 341
  commits, active through Aug 2026. Zig + **LuaJIT scripting layer** +
  `libghostty-vt`. **Windows-native is the primary target**; WSL is
  first-class (optional PTY-bypass helper with ConPTY fallback); tabs,
  splits, floating panes, **workspaces**, quick-select for
  links/IPs/paths, Kitty images + Sixel, plugin system
  ([repo](https://github.com/sudo-tee/hollow)). The most
  product-differentiated rival in the field.
- **[ibuildthecloud/winterm-ghostty](https://github.com/ibuildthecloud/winterm-ghostty)**
  — 5★ but new (2026-08-07) and strategically clever: patches Windows
  Terminal so a pane with `"engine": "ghostty"` renders via
  `libghostty.dll` (D3D11) into WT's own XAML `SwapChainPanel`; tabs,
  panes, settings stay WT's. 31 patches vs ghostty, 42 vs
  microsoft/terminal; self-signed MSIX installs alongside WT; phase 6
  of 9 done, **upstreaming to both projects is a stated phase**;
  measured pty drain 28 MB/s vs stock 38.1 MB/s; accessibility
  explicitly unimplemented. Author (Darren Shepherd, Rancher co-founder)
  has real distribution instincts: ride the incumbent instead of
  fighting it.
- Periphery: [ghosttea](https://github.com/vibecook-dev/ghosttea)
  (libghostty in Electron/WebGPU), [rustty](https://github.com/arc-source-coder/rustty)
  (GPUI, 0★), [wmux](https://github.com/rcv-goku/wmux) ("terminal
  multiplexer for Windows powered by Ghostty," 1★, active Aug 2026).

**C. WSL-bridge:**
[Codavo/ghostinthewsl](https://github.com/Codavo/ghostinthewsl) — 53★/5.
Windows-native UI + a small bridge inside the WSL guest speaking
**Hyper-V sockets/VSOCK instead of ConPTY**, allocating real Linux
PTYs — full kitty graphics, terminfo auto-install, WSL keepalive,
portable exe, six CI-built releases 0.1.0→0.1.5 (Apr–Aug; GitHub omits
the year on the page — the Aug 2 release matches Aug 2, 2026 discussion
activity, so current-cycle). Builds on a mattn community branch and
states it will retarget upstream once Windows support lands.

**D. Upstream-convergent (the real competition):**
[deblasis/wintty](https://github.com/deblasis/wintty) (separate dive)
has **17 PRs merged into ghostty-org/ghostty** (build/CI/DLL
infrastructure) and continues as a soft fork "since upstream doesn't
have capacity to maintain Windows-specific changes right now."
**mattn** (high-credibility Windows/Go OSS figure) posted 2026-04-24
that his ghostty Windows work is "currently at Tier 2" of upstream's
phased plan ([tweet](https://x.com/mattn_jp/status/2047869881446801636);
his [fork](https://github.com/mattn/ghostty) has 45★). Upstream's
[Windows Support discussion #2563](https://github.com/ghostty-org/ghostty/discussions/2563)
reports Windows CI tests running by Dec 2025 and April 2026 contributor
guidance: **Direct3D renderer, Windows 10/11 only, minimal C++** — i.e.
upstream is accepting incremental Windows work while explicitly
declining to promise an official port
([community thread #12371](https://github.com/ghostty-org/ghostty/discussions/12371):
"explicitly _not_ about making an official Ghostty version for
Windows"). Governance context: Ghostty is now a nonprofit paying
contributors, with a vouch-gated contribution model
([PR #10559](https://github.com/ghostty-org/ghostty/pull/10559)), and
mitchellh says libghostty "backs more than a dozen terminal projects"
and predicts libghostty users "will dwarf" GUI users by mid-2027
([HN](https://news.ycombinator.com/item?id=47207472)).

**Trademark (load-bearing).** In #12371, Crypto-Spartan asked (Jul 12, 2026) "has anyone used github.com/amanthanvi/winghostty?" and
collaborator pluiedev replied the same day: "Note that projects
unaffiliated with the Ghostty project must not use 'Ghostty' as a part
of their branding, since it's a trademark owned by our nonprofit and
not open for the public to freely use," adding that fork maintainers
should be told "they need to find a different name"
([#12371](https://github.com/ghostty-org/ghostty/discussions/12371)).
winghostty was the named trigger for this statement. WolftacDigital's
rename to "Spectre" shows the policy already reshaping the field.

## 2. Performance & fluidity

- Renderer split across the family: **D3D11 + DirectWrite** is the
  dominant choice (adilahmeddev lineage, mite, winterm-ghostty, zcg's
  D2D/D3D11) — and matches upstream's stated Direct3D preference for
  eventual official Windows work (#2563, Apr 2026 guidance). shiweis
  is the OpenGL 4.6/WGL outlier; winghostty (OpenGL 4.3/WGL + separate
  D3D11/DComp chrome) sits closer to shiweis than to upstream's stated
  direction.
- The only published throughput number in the family: winterm-ghostty's pty drain
  throughput — ghostty pane ~28 MB/s vs Windows Terminal's cascadia
  38.1 MB/s after optimization
  ([repo](https://github.com/ibuildthecloud/winterm-ghostty)) — i.e.
  the one measured effort is currently _slower_ than the incumbent.
- mite's <2 MB optimized exe is a startup/footprint benchmark claim
  worth remembering ([repo](https://github.com/marler8997/mite)).
- No fork publishes latency, frame-time, or scroll benchmarks. Nobody
  in the field can substantiate a fluidity story; winghostty could own
  this axis simply by measuring.

## 3. Native Windows integration

- **ConPTY vs alternatives:** all hard forks use ConPTY.
  ghostinthewsl's VSOCK bridge to real Linux PTYs is the family's one
  genuinely novel integration idea — it bypasses ConPTY's throughput
  and escape-sequence lossiness for WSL sessions entirely, with
  terminfo auto-install and WSL VM keepalive
  ([repo](https://github.com/Codavo/ghostinthewsl)); one #12371
  commenter alternatively embeds a newer ConPTY (Aug 2, 2026). This is
  the strongest technical challenge to winghostty's WSL story, which is
  plain ConPTY.
- **IME:** the Thr45hx build ships with IME cursor-positioning broken
  ([BUILD-LOG](https://github.com/Thr45hx/ghostty-windows/blob/master/BUILD-LOG.md));
  shiweis claims working CJK IME. winghostty's shipped IME is ahead of
  the lineage snapshot.
- **Chrome:** zcg had Mica/Acrylic custom title bars; shiweis/Thr45hx
  use GDI overlays for tabs/search/palette — cheaper than winghostty's
  DirectWrite/DComp chrome pipeline but visually cruder.
- Nobody in the family documents Snap Layouts, jump lists, taskbar
  progress, default-terminal registration, or ARM64. **No fork ships
  ARM64** (Thr45hx is x64-only by name); winghostty's ARM64 support is
  unique in the entire field.
- winterm-ghostty inherits _all_ of Windows Terminal's integration
  (Snap, jump lists, default-terminal handoff, MSIX) for free — the
  structural advantage of riding the incumbent shell.

## 4. Terminal capability

All archetype-A/B efforts inherit Ghostty's VT core, so paper
capability (VT depth, Kitty graphics, OSC 8/52, mouse modes) is
identical to winghostty's; differences are in what the platform layer
actually delivers:

- shiweis claims full VT + Kitty graphics under OpenGL 4.6 and 463
  built-in themes, URL detection, search
  ([README](https://github.com/shiweis/ghostty-windows)) — unverified,
  no binaries.
- ghostinthewsl delivers kitty graphics _through real Linux PTYs_,
  sidestepping ConPTY stripping — for WSL-heavy users this is a real
  capability delta over every ConPTY-based port including winghostty.
- winterm-ghostty: rendering, input, selection, clipboard, search,
  marks, IME "all work" per README; screen readers cannot read ghostty
  panes (accessibility unstarted).
- hollow adds keyboard quick-select of links/IPs/paths/filenames — a
  keyboard-first capability winghostty lacks.
- Upstream tracking matters for capability drift: shiweis merges
  upstream main continuously (Zig 0.16, Kitty-image fixes, July 2026);
  a hard fork that stops merging (Thr45hx, frozen at 1.3.0-dev) decays
  against Ghostty 1.3+ features like scrollback search.

## 5. Workflow features

- Tabs + splits: table stakes across the family (Thr45hx, shiweis,
  hollow, winterm via WT).
- **Quick/dropdown terminal with global hotkey:** shiweis ships it;
  winghostty has no such surface (echoes the long-tail finding).
- **Command palette:** shiweis has a filterable action palette;
  winghostty's universal palette (blended actions/tabs/panes/profiles/
  themes/settings) is richer than anything in the field.
- **Workspaces:** hollow's workspaces + floating/maximized panes go
  beyond winghostty's window/tab/split model.
- **Session restore: nobody in the family has it.** No fork documents
  layout persistence, let alone winghostty's windows/tabs/splits/
  profiles/cwd restore with quarantine-and-safe-mode recovery. This is
  winghostty's single clearest workflow moat over the family.
- Broadcast input, profiles-as-UI, undo/redo of structural operations:
  absent everywhere except winghostty.

## 6. Reliability & quality signals

- **AI-generation is the family's defining quality pattern:** Thr45hx
  openly Claude-built; shiweis commits co-authored by "claude"; zcg
  archived itself as an unmaintained "GPT-5.4 era" artifact; the mirror
  clones look machine-produced. Claims like "feature-complete, 66/66
  actions" ship without releases, CI badges, or third-party
  verification.
- Bus factor is 1 everywhere; the lineage root vanished without notice
  (adilahmeddev 404), and downstream repos now cite a dead upstream.
- Positive signals worth noting: shiweis's 25+ scripted PowerShell/WSL2
  UI tests and disciplined upstream-merge policy; winterm-ghostty's
  phased plan with test harnesses and pinned-commit + patch-series
  reproducibility; ghostinthewsl's CI-built releases with changelog.
- Issue trackers are thin (Thr45hx: 1 open; shiweis: low; winterm: 12,
  mostly author's own tracking) — too little usage to mine crash
  patterns. Absence of complaint here is absence of users, not
  presence of quality.

## 7. Configuration & extensibility

- Forks inherit Ghostty's config grammar unchanged; none add a
  settings GUI (winghostty's native settings window is unique in the
  field).
- **hollow's LuaJIT layer** (`hollow.config/term/events/keymap/ui/htp`
  APIs, plugin system for custom panes/overlays/widgets) is the
  family's only real extensibility story — WezTerm/Neovim-style, aimed
  squarely at the keyboard-first tinkerer
  ([repo](https://github.com/sudo-tee/hollow)). PRODUCT.md has no
  scripting category; this is where a rival differentiates without
  touching performance.
- winterm-ghostty extends Windows Terminal's `settings.json`
  (`"engine": "ghostty"` per profile) — zero new config surface for
  users to learn.

## 8. Packaging & adoption

Traction snapshot (2026-08-17, GitHub):

| Project                 | Stars   | Releases                   | Signing      | Package mgr    | Active?                 |
| ----------------------- | ------- | -------------------------- | ------------ | -------------- | ----------------------- |
| **winghostty**          | 255     | v1.3.123 (Aug 6)           | Authenticode | winget + Scoop | yes                     |
| Thr45hx/ghostty-windows | 59      | 1 (unsigned Inno, SHA-256) | none         | none           | barely                  |
| Codavo/ghostinthewsl    | 53      | 6 CI releases              | none stated  | none           | yes                     |
| mattn/ghostty (fork)    | 45      | —                          | —            | —              | yes (upstream-directed) |
| shiweis/ghostty-windows | 38      | **none** (build-only)      | n/a          | none           | yes                     |
| zcg/ghostty-win         | 27      | none                       | n/a          | none           | **archived**            |
| mite / hollow           | 22 / 22 | none / none stated         | none         | none           | idle / yes              |
| winterm-ghostty         | 5       | MSIX (self-signed)         | self-signed  | none           | yes (new)               |

- winghostty leads the family on every distribution axis: the only trusted (non-self-signed) Authenticode-signed binaries, only winget/Scoop presence, only updater with
  checksum+Authenticode gating. The sweep's judgment stands and is now
  quantified.
- Fork onboarding friction is severe: shiweis (the most capable hard
  fork) requires installing Zig 0.16 and cross-compiling; Thr45hx's
  installer needs admin and previously _corrupted PATH_
  ([release notes](https://github.com/Thr45hx/ghostty-windows/releases)).
- Nobody except winghostty documents an update mechanism.

## 9. What users complain about

Direct user feedback on the forks is sparse (few users); the observable
complaints are field-level:

- **Fork confusion:** the question that triggered the trademark
  statement — "has anyone used winghostty?" — was asked _inside
  upstream's ports thread_ because users cannot evaluate the swarm
  ([#12371](https://github.com/ghostty-org/ghostty/discussions/12371)).
- **Branding pushback from upstream** is itself the loudest recorded
  "complaint" about the family, winghostty included (same thread).
- Thr45hx's own release notes document the classic unsigned-solo-build
  failure modes users hit: AVX-512 crash on older CPUs, PATH
  corruption by the installer, missing themes/shell-integration files.
- Upstream discussion sentiment (#2563): years of pent-up demand
  ("I would love ghostty.exe to run as a Windows .exe"), impatience
  with WSL workarounds — demand winghostty can serve _today_ but only
  if discoverable and trusted.
- jeffquast-style third-party verification does not exist for any fork;
  "stable for daily use" claims circulate unchallenged — a trust vacuum.

## 10. Lessons for winghostty

**Strategic verdict on the ticket's question:** no hard fork is likelier
than winghostty to become the de-facto Ghostty on Windows — winghostty
leads on traction, packaging, trust, and feature completeness, and the
lineage is decaying (root deleted, one archive, one frozen). The
credible claimants to "THE Ghostty on Windows" are (a) **upstream
itself**, arriving incrementally via the tiered plan, mattn, and
wintty's merged infrastructure PRs, and (b) **libghostty consumers**,
the shape upstream is institutionally building toward — including
winterm-ghostty's ride-the-incumbent wedge. The fragmented field does
change winghostty's posture: the trademark statement puts "generic Ghostty fork" positioning in direct conflict with upstream's stated branding policy, and the fork swarm makes
trust signals (signing, verification, benchmarks) the deciding axis.

### Does well (adopt-candidates)

- **Quick terminal (global-hotkey slide-in)** — shiweis ships it; no
  winghostty surface (docs/status.md), and the long-tail sweep flagged
  the same gap ([shiweis](https://github.com/shiweis/ghostty-windows)).
- **WSL PTY bypass via Hyper-V sockets/VSOCK** — real Linux PTYs, full
  kitty graphics, terminfo auto-install, WSL keepalive vs winghostty's
  plain-ConPTY WSL ([ghostinthewsl](https://github.com/Codavo/ghostinthewsl)).
  The keepalive alone is a cheap adopt.
- **Explicit upstream-merge cadence, documented** — shiweis's visible
  "merged N upstream commits" policy keeps Ghostty 1.3+ capability
  current; winghostty's docs state no drift/merge policy
  ([commits](https://github.com/shiweis/ghostty-windows/commits/main)).
- **Keyboard quick-select of links/paths/IPs on screen** (hollow) —
  pure keyboard-first territory PRODUCT.md claims but doesn't cover
  ([hollow](https://github.com/sudo-tee/hollow)).
- **D3D11/DirectWrite terminal rendering path** — the family majority
  _and_ upstream's stated preference (#2563 Apr 2026 guidance); a
  D3D11 renderer option would future-proof winghostty against
  upstream-alignment work and Intel/OpenGL-driver pain.
- **Reproducibility discipline** — winterm-ghostty's pinned-commit +
  exported-patch-series model makes a fork auditable; good answer to
  "how do I know what you changed?"
  ([winterm-ghostty](https://github.com/ibuildthecloud/winterm-ghostty)).
- **Desktop notifications (OSC 9/777-style)** — shiweis lists them;
  absent from winghostty's documented surface.

### Does badly (avoid / exploit)

- **Unverifiable AI-generated capability claims** ("feature-complete,"
  "66/66 actions") with no binaries, signing, or third-party tests —
  exploit by publishing signed releases _plus_ verification: conformance
  results, benchmark numbers, test-suite badges. Trust is the moat the
  swarm cannot cross.
- **No releases at all** (shiweis) or unsigned admin-rights installers
  that corrupted PATH (Thr45hx) — winghostty's
  Authenticode + winget/Scoop + gated updater is its clearest edge;
  keep it loud in positioning.
- **Bus-factor-1 disappearance**: the lineage root deleted itself;
  zcg archived with an abandonment note. Exploit: visible governance,
  succession notes, and release cadence as advertised reliability.
- **Frozen snapshots decay** — Thr45hx is stuck at 1.3.0-dev while
  upstream ships scrollback search etc.; avoid by institutionalizing
  upstream merges (see adopt list).
- **x64-only everywhere** — winghostty's ARM64 build is unique in the
  entire family; advertise it.
- **Accessibility ignored across the field** (winterm-ghostty admits
  screen readers can't read its panes; nobody else mentions UIA) —
  winghostty's partial UIA/TextPattern work is a differentiator worth
  finishing and stating.

### Blind-spot candidates

- **Trademark/naming risk is live, specific, and aimed at winghostty**:
  upstream collaborator, Jul 12 2026 — unaffiliated projects "must not
  use 'Ghostty' as a part of their branding"; maintainers should be
  told "they need to find a different name"
  ([#12371](https://github.com/ghostty-org/ghostty/discussions/12371)).
  PRODUCT.md has no naming/trademark/upstream-relations category.
  Options to evaluate: proactive rename (cf. WolftacDigital→Spectre),
  or seeking explicit permission; drifting invites a forced rename at
  a worse time.
- **libghostty as the sanctioned integration shape**: upstream's
  nonprofit, paid contributors, vouch-gated contribution model
  ([PR #10559](https://github.com/ghostty-org/ghostty/pull/10559)),
  and mitchellh's mid-2027 libghostty prediction
  ([HN](https://news.ycombinator.com/item?id=47207472)) mean the
  blessed path is "app built on libghostty," not "fork of ghostty."
  PRODUCT.md has no category for how winghostty relates to that
  trajectory (track libghostty API? restructure toward it? ignore?).
- **Upstream Windows arrival as a dated threat**: Windows CI (Dec
  2025), tier plan with D3D/Win10-11/minimal-C++ guidance (Apr 2026),
  mattn on Tier 2, wintty's 17 merged PRs — an official or blessed
  Windows Ghostty plausibly lands within winghostty's planning horizon.
  No PRODUCT.md category answers "what is winghostty when upstream
  ships Windows?" (Candidate answer: the session-restore + native-
  polish + trust product — the things upstream's tiers won't do first.)
- **Upstreaming as strategy**: wintty converted Windows work into 17
  merged upstream PRs and goodwill; winghostty contributes nothing
  upstream today. Separable pieces (build fixes, ConPTY glue, VT
  conformance results) could buy standing under the vouch model —
  relevant if a naming/permission conversation ever happens.
- **Ride-the-incumbent distribution** (winterm-ghostty): shipping the
  engine inside Windows Terminal turns the platform default from enemy
  into channel. Not winghostty's play, but a category of competitor
  PRODUCT.md doesn't anticipate: users who get "Ghostty rendering"
  without leaving Windows Terminal.
- **Fork-field hygiene as user-facing content**: a "why winghostty /
  how we differ from the swarm / how to verify our binaries" page
  converts the confusion documented in #12371 into acquisitions;
  nothing in PRODUCT.md covers competitive self-identification.
