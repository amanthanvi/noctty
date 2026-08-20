# Deep dive: Wave Terminal (wavetermdev/waveterm)

Research date: 2026-08-17. All claims sourced; hands-on claims none.

## Executive summary

Wave is the category's flagship "terminal becomes an infrastructure
workspace" bet — Apache-2.0, Electron + Go, 22.1k stars, blocks/widgets,
SSH-durable sessions, and an AI-first roadmap — and it is simultaneously
the best evidence that the bet does not displace terminal-first products:
its xterm.js core lacks any graphics protocol and synchronized output,
keybinding customization is still a top open request, WSL is modeled as a
remote "connection" rather than a first-class shell, and Windows is
x64-only. Most important new finding: development has visibly stalled —
no release since v0.14.5 (2026-04-16) and zero public commits from
founder/CEO Mike Sawka anywhere on GitHub since 2026-05-10, with the repo
coasting on dependabot and drive-by PRs against 451 open issues.

## 1. Identity & strategy

- **What it is:** "An open-source, AI-integrated, cross-platform terminal
  for seamless workflows" — a tiled workspace of *blocks*: terminals,
  remote file editor, file previews (markdown/images/video/PDF/CSV),
  embedded web browser, AI chat, sysinfo graphs, process viewer
  ([repo](https://github.com/wavetermdev/waveterm)).
- **Who:** Command Line Inc, San Francisco; founder/CEO Mike Sawka
  (GitHub `sawka`) ([RocketReach profile](https://rocketreach.co/michael-sawka-email_84251897),
  [sawka](https://github.com/sawka)). Funding amounts not publicly
  disclosed (PitchBook/Crunchbase profiles exist but are paywalled;
  treat as VC-backed-scale-unknown). Monetization stated at launch as
  "free locally, paid for server/team features"
  ([Show HN, Dec 2023](https://news.ycombinator.com/item?id=38701899));
  today the visible revenue surface is GitHub Sponsors
  ([sponsors/wavetermdev](https://github.com/sponsors/wavetermdev)).
- **History — a full rewrite already:** started as "Prompt," renamed Wave
  v0.5.0 (Nov 2023); the original block-per-command architecture was
  **abandoned** at v0.7.7 (2024-09-20, "the last on our legacy codebase")
  and replaced by a complete rewrite (v0.8+) around a conventional
  terminal inside a tiled layout
  ([legacy release notes](https://legacydocs.waveterm.dev/releasenotes)).
- **Strategy now:** the [ROADMAP](https://github.com/wavetermdev/waveterm/blob/main/ROADMAP.md)
  is overwhelmingly AI: providers, AI file-editing, AI-powered custom
  widgets ("Tsunami" Go framework + visual "AI Widget Builder"). Command
  palette and keybinding customization sit in the non-AI "planned" tail.
- **License/governance:** Apache-2.0; single-company governance, and the
  bus factor is now demonstrably live (see §6).

## 2. Performance & fluidity

- **Architecture:** Electron front end (React/TypeScript), Go backend
  (`wavesrv`) that owns ptys/connections/storage; terminal rendering is
  **xterm.js v6** (upgraded v0.14.4, 2026-03-26) with WebGL (config key
  `window:disablewebgl` [commit c2a17e7](https://github.com/wavetermdev/waveterm/commit/c2a17e7eb2ac44b867277e8ca9da2a9fbff843c5)),
  inside a custom tiled layout engine
  ([release notes](https://docs.waveterm.dev/releasenotes)).
- **No published benchmarks** of latency/throughput from the project.
- Third-party 2026 review: **400–800 MB memory**, "resize lag" and
  "occasional jank," "not recommended for people running a CLI agent all
  day" due to visual glitches
  ([moltamp review](https://moltamp.com/blog/wave-terminal-review-2026/)).
  At launch an HN user measured 170→200 MB for a single tab
  ([HN](https://news.ycombinator.com/item?id=38701899)).
- Open perf issues: "changing font size is extremely laggy"
  ([#3354](https://github.com/wavetermdev/waveterm/issues/3354)),
  "Electron memory leak"
  ([#2731](https://github.com/wavetermdev/waveterm/issues/2731)).
  v0.14.0/v0.14.4 did real plumbing work (RPC streaming with flow
  control) ([release notes](https://docs.waveterm.dev/releasenotes)).
- Startup time: no data found (uncertain).

## 3. Native Windows integration

- **Windows 10 1809+ x64 only.** No ARM64 — open request since Oct 2024
  ([#928](https://github.com/wavetermdev/waveterm/issues/928)).
  winghostty ships ARM64 today (docs/status.md).
- **ConPTY:** delegated to a community fork — `go.mod` replaces
  `creack/pty` with `photostorm/pty` **pinned to a Sep 2023 commit**
  ([go.mod](https://raw.githubusercontent.com/wavetermdev/waveterm/main/go.mod)).
  ConPTY handling is thus a frozen third-party dependency, not owned code.
- **WSL is a "connection," not a shell:** integrated via
  `ubuntu/gowsl` and treated like SSH targets. Consequences users hit:
  cannot make WSL the default local terminal
  ([#2073](https://github.com/wavetermdev/waveterm/issues/2073), open
  since 2025-03), connection failures ("unable to determine os",
  [#1666](https://github.com/wavetermdev/waveterm/issues/1666); can't
  connect to WSL, [#1259](https://github.com/wavetermdev/waveterm/issues/1259)),
  env vars/init scripts ignored in WSL
  ([#2177](https://github.com/wavetermdev/waveterm/issues/2177)).
- **No multiple local shell profiles on Windows** — still an open feature
  request ([#2209](https://github.com/wavetermdev/waveterm/issues/2209));
  Git Bash auto-detection only arrived v0.13.1 (Dec 2025)
  ([release notes](https://docs.waveterm.dev/releasenotes)).
- **Chrome:** Electron; a separate Windows title bar was only merged into
  an integrated header in v0.13.1 (Dec 2025). No evidence of Snap
  Layouts, jump lists, taskbar progress, default-terminal registration,
  Explorer integration, or elevation handling (an "admin console" ask is
  open, [#3298](https://github.com/wavetermdev/waveterm/issues/3298)).
- **Signing/packaging:** Windows builds (NSIS exe, MSI, zip) are
  Authenticode-signed as "Command Line Inc" via DigiCert Software Trust
  Manager ([electron-builder.config.cjs](https://raw.githubusercontent.com/wavetermdev/waveterm/main/electron-builder.config.cjs)).
  Still gets AV false positives (Avast flags it,
  [#2214](https://github.com/wavetermdev/waveterm/issues/2214)).

## 4. Terminal capability

The terminal itself is capped at xterm.js's ceiling, and Wave trails
even that:

- **No graphics protocol at all** — no sixel, Kitty, or iTerm2 images;
  "[Feature]: Support a graphics protocol" open since May 2025 with only
  4 reactions ([#2172](https://github.com/wavetermdev/waveterm/issues/2172)).
  (Wave's answer is out-of-band: preview *widgets* render images/files —
  which is precisely the workspace-instead-of-VT philosophy.)
- **No synchronized output (mode 2026)** — TUI animations scroll instead
  of animating in place
  ([#2787](https://github.com/wavetermdev/waveterm/issues/2787)).
- **Late basics:** OSC 7 cwd tracking only in v0.12.1 (Oct 2025); OSC 52
  clipboard only in v0.14.0 (Feb 2026); bracketed-paste improvements
  v0.13.0 ([release notes](https://docs.waveterm.dev/releasenotes)).
- Wrapped/cursor-positioned output **copy is mangled**, "especially
  painful on Windows + WSL"
  ([#3288](https://github.com/wavetermdev/waveterm/issues/3288));
  tmux scroll/copy problems
  ([#3310](https://github.com/wavetermdev/waveterm/issues/3310),
  [#2646](https://github.com/wavetermdev/waveterm/issues/2646)).
- Shell integration (bash/zsh/fish/pwsh) exists mainly to feed **AI
  context** (shell state, exit codes, command history)
  ([v0.12.1 notes](https://docs.waveterm.dev/releasenotes)).
- Contrast: winghostty inherits Ghostty's full VT core with Kitty
  graphics, validated Win32 conformance (docs/windows-vt-conformance.md).

## 5. Workflow features

- **Blocks + tiled layout** instead of classic splits; tabs, vertical
  tabs (v0.14.4), workspaces; layout persists across restarts (local
  shell processes do not survive).
- **Durable sessions are SSH-only and opt-in**: a remote job manager
  keeps the shell alive over Unix domain sockets and buffers output;
  "Local terminals and WSL connections use standard sessions"
  ([durable sessions doc](https://docs.waveterm.dev/durable-sessions)).
  Users are already asking for local durability
  ([#3248](https://github.com/wavetermdev/waveterm/issues/3248)).
- **Quake-mode global hotkey** shipped v0.14.5 (2026-04-16)
  ([release notes](https://docs.waveterm.dev/releasenotes)).
- **`wsh` CLI** scripts the workspace (open editors/previews, set config,
  manage secrets/badges; `wsh tab list/move` added by a community PR July
  2026 — [commit 3ad0aca](https://github.com/wavetermdev/waveterm/commit/3ad0acadf852117a13d666b96e42af7db973acdf)).
  But `wsh` is injected onto SSH hosts (rc-file wiring), which drew
  security-minded criticism at launch
  ([HN](https://news.ycombinator.com/item?id=38701899)) and generates
  breakage issues ([#2026](https://github.com/wavetermdev/waveterm/issues/2026),
  [#3373](https://github.com/wavetermdev/waveterm/issues/3373),
  [#1452](https://github.com/wavetermdev/waveterm/issues/1452)).
- **No command palette** (roadmap: planned). **Keybindings are largely
  fixed**: editing default shortcuts is a 12-reaction open request from
  Feb 2025 ([#1943](https://github.com/wavetermdev/waveterm/issues/1943));
  disabling individual bindings likewise open
  ([#3323](https://github.com/wavetermdev/waveterm/issues/3323));
  "Advanced keybinding customization" is merely "planned" on the
  [roadmap](https://github.com/wavetermdev/waveterm/blob/main/ROADMAP.md).
  For a keyboard-first user this is disqualifying; winghostty's full
  keybind grammar + universal palette is a direct edge.
- Other: secrets store with OS-native backends, block badges, process
  viewer, focus-follows-cursor, vim-style block navigation (v0.14.1).

## 6. Reliability & quality signals

- **Stall signal (the headline):** last release v0.14.5 on 2026-04-16 —
  4 months ago against a prior 2–6 week cadence
  ([releases](https://github.com/wavetermdev/waveterm/releases)); the
  founder has **zero public commits anywhere on GitHub since 2026-05-10**
  (GitHub commit search `author:sawka committer-date:>=2026-05-10` →
  0 results; last waveterm commit 2026-05-04,
  [021db67](https://github.com/wavetermdev/waveterm/commit/021db67ee7af1771d0b4b9bf09c098fa7747e5cd)).
  June–July commits are ~80% dependabot plus one community contributor
  ([commits feed](https://github.com/wavetermdev/waveterm/commits/main.atom)).
  *Uncertain why*: private-repo work (e.g., the Tsunami "builder"
  product his April commits centered on), a pivot, or wind-down — no
  public statement found.
- **Backlog:** 451 open issues, 101 open PRs
  ([repo](https://github.com/wavetermdev/waveterm)).
- Recurring regression areas: IME/CJK (fixed twice: v0.12.3, v0.14.1),
  scroll behavior (Claude Code jump bug lived long enough to be a
  headline fix in v0.14.1), copy/paste, WSL connectivity.
- CI/test story: dependabot hygiene is active; no published conformance
  or perf test suite for the terminal itself (uncertain beyond that).

## 7. Configuration & extensibility

- JSON config files (`settings.json`, `connections.json`,
  `widgets.json`), CLI mutation via `wsh setconfig` / `wsh setmeta`,
  presets/backgrounds; no GUI settings app (a config *widget* shipped
  v0.13.0) ([docs](https://docs.waveterm.dev/)).
- **Custom widgets** today are config-composition only: terminal/CLI,
  web, and sysinfo widget types declared in `widgets.json`
  ([customwidgets doc](https://docs.waveterm.dev/customwidgets)).
- **Tsunami**: an in-repo Go widget framework (React-like shadow
  component tree, hooks, vdom) plus an AI "builder" — the intended real
  extensibility story, still unshipped/in-progress
  ([pkg.go.dev](https://pkg.go.dev/github.com/wavetermdev/waveterm/tsunami/engine),
  [roadmap](https://github.com/wavetermdev/waveterm/blob/main/ROADMAP.md)).
- **Telemetry: opt-out, on by default** (app/system info, feature usage,
  connection events, AI token counts; no PII/commands/prompts), disable
  via settings or `WAVETERM_NOPING`
  ([telemetry doc](https://docs.waveterm.dev/telemetry)). Early BYOK
  required telemetry until community pushback removed that (v0.13.1).

## 8. Packaging & adoption

- Channels: GitHub releases (exe/MSI/zip, signed), **winget
  `CommandLine.Wave`**, official Chocolatey package (org repo), AUR;
  **no Scoop** (request open,
  [ScoopInstaller/Extras#14683](https://github.com/ScoopInstaller/Extras/issues/14683)).
- Docs site is genuinely good: per-feature pages, keybindings, wsh
  reference, telemetry disclosure, release notes
  ([docs.waveterm.dev](https://docs.waveterm.dev/)).
- Momentum: 22.1k stars / 1.1k forks / 85 watchers
  ([repo](https://github.com/wavetermdev/waveterm)); HN launch was
  modest (82 points Show HN Dec 2023,
  [thread](https://news.ycombinator.com/item?id=38701899)). Download
  counts not published (uncertain). Star count vs. the 2026 stall is a
  live rerun of the long-tail sweep's Hyper lesson: stars lag,
  cadence tells the truth.

## 9. What users complain about

- **"All I want is a terminal":** "The ui looks extremely cluttered when
  all I want is a terminal" ([HN launch](https://news.ycombinator.com/item?id=38701899));
  requests to hide tab bar/side bar are the most-thumbed open UX issue
  ([#1022](https://github.com/wavetermdev/waveterm/issues/1022), +8).
- **Memory/Electron tax:** 170–200 MB per tab at launch (HN), 400–800 MB
  in 2026 review with resize jank ([moltamp](https://moltamp.com/blog/wave-terminal-review-2026/)).
- **Fixed keybindings** ([#1943](https://github.com/wavetermdev/waveterm/issues/1943), top-reacted).
- **wsh auto-install on remote hosts** — "automatic deployment of helper
  software to SSH'd machines" spooked sysadmins (HN), and wsh breakage
  is a steady issue stream.
- **AI judged generic:** "a thin layer over OpenAI by default … users
  who already use Claude Code or Gemini CLI will run those inside Wave"
  ([moltamp](https://moltamp.com/blog/wave-terminal-review-2026/));
  ironically Anthropic-native support is still only "planned" on the
  roadmap.
- **Blocks paradigm friction:** "Wave's blocks feel like extra work for
  the first few days" (ibid.); tmux users bounce.
- **Windows+WSL copy corruption** ([#3288](https://github.com/wavetermdev/waveterm/issues/3288)),
  x64-only ([#928](https://github.com/wavetermdev/waveterm/issues/928)).

## 10. Lessons for winghostty

### Does well (adopt-candidates)

1. **Durable sessions as a named, marketed feature.** Wave's SSH-only
   job-manager design proves demand and even shows the gap (users
   immediately asked for *local* durability, [#3248](https://github.com/wavetermdev/waveterm/issues/3248)).
   winghostty's `window-save-state` restores layout but not
   contents/processes (docs/status.md) — local durable sessions on
   Windows (ConPTY child survives UI restart) would leapfrog Wave.
2. **Quake-mode global hotkey** (v0.14.5) — rubric §5 surface with no
   winghostty equivalent.
3. **`wsh`-grade workspace scriptability.** winghostty's
   `+perform-action`/`+list-windows` IPC is a seed; Wave shows the
   value of a full verb set (open/edit/set-config/tab management) —
   without Wave's remote-injection mistake.
4. **First-class file preview as opt-in surface.** "Open a CSV, get a
   real table" is Wave's most-praised non-AI feature. A bounded,
   keyboard-first equivalent (preview pane for images/markdown via
   Kitty graphics winghostty already renders) is worth a category
   discussion, not reflexive rejection.
5. **Secrets in OS-native storage** exposed to shells on demand —
   Windows Credential Manager integration would be the native analog.
6. **Docs transparency:** a dedicated, plain-language telemetry page
   (even though winghostty collects nothing — say so as loudly).
7. **winget + Chocolatey coverage:** Wave ships winget *and* choco;
   winghostty has winget + Scoop; add Chocolatey for enterprise parity.

### Does badly (avoid / exploit)

1. **Terminal fundamentals sacrificed to the workspace:** no graphics
   protocol ([#2172](https://github.com/wavetermdev/waveterm/issues/2172)),
   no synchronized output ([#2787](https://github.com/wavetermdev/waveterm/issues/2787)),
   late OSC 7/52, mangled copies. Exploit: publish winghostty's VT
   conformance matrix as a comparison asset.
2. **Electron floor:** 400–800 MB and resize jank; "not for people
   running a CLI agent all day" — the exact user winghostty targets in
   2026. Publish footprint/latency comparisons.
3. **Fixed keybindings + no command palette** in a developer tool —
   winghostty's keybind grammar + universal palette is a direct,
   demonstrable edge; keep it prominent in messaging.
4. **WSL modeled as a remote connection** with chronic breakage —
   winghostty's WSL-as-profile approach is what the benchmark user
   wants; never regress it into a "connection manager."
5. **ConPTY outsourced to a stale fork** (photostorm/pty pinned to
   2023) vs. winghostty owning its pty path — reliability moat.
6. **Single-founder company stall:** cadence collapsed within weeks of
   the founder going quiet, despite 22k stars. Keep winghostty's
   status.md/date-stamped honesty and visible cadence; weight
   competitors by cadence, not stars.
7. **AI-first roadmap crowding out terminal work** (command palette and
   keybindings languish behind an AI widget builder) — validates
   PRODUCT.md's anti-reference against feature-count competition.
8. **Full rewrite mid-life** (legacy Wave → v0.8) reset trust and
   ecosystem once already — architecture bets that require rewrites are
   existential for small teams.
9. **x64-only Windows** — advertise winghostty ARM64 support.
10. **Opt-out telemetry and BYOK-gated-on-telemetry stumbles** — never
    replicate; zero-telemetry is a stated winghostty differentiator.

### Blind-spot candidates (no PRODUCT.md category)

1. **Local durable sessions** — processes/contents surviving app
   restart is becoming an expectation (Wave ships it for SSH; users
   demand it locally). PRODUCT.md's "session layout survives restarts"
   stops short of the emerging bar.
2. **Workspace scriptability as a product surface** — a supported CLI
   verb set over the running app (Wave's `wsh`), beyond winghostty's
   allowlisted automation; enables user tooling and tests.
3. **Structured secret injection** — OS-keychain-backed secrets
   available to shells without dotfile plaintext.
4. **Non-terminal read surfaces** (file/data preview inside the
   terminal app) — PRODUCT.md has no category for deciding what
   *adjacent content* the terminal may render; Wave shows demand and
   the overreach failure mode (embedded browser).
5. **AI-context plumbing without AI features:** Wave's OSC-based shell
   state/exit-code/history tracking exists to feed agents. A terminal
   that exposes clean, local, consent-gated context (scrollback query,
   prompt-mark structure) to *external* CLI agents (Claude Code et al.)
   serves the same demand without bundling a chatbot — nothing in
   PRODUCT.md contemplates the terminal as an agent's host environment,
   yet "CLI agent all day" is now a primary Windows dev workload.
6. **Company-form risk as a competitive lens** — evaluating rivals (and
   presenting winghostty) on sustainability/bus-factor, which Wave's
   2026 stall shows can invert a category leader in one quarter.

### Strategic verdict on the dive question

Wave *validates* winghostty's terminal-first frame rather than
threatening it: the workspace drift wins press and stars, but the
benchmark keyboard-first Windows developer shows up in Wave's own issue
tracker asking for hideable chrome, rebindable keys, working WSL, clean
copies, and local durability — i.e., asking Wave to be more like a
terminal. The durable-session, scriptability, and preview ideas are real
and adoptable piecemeal; the bundle (Electron + widgets + AI panes) is
the part that stalls under its own weight.
