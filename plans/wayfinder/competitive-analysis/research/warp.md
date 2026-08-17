# Warp (Windows build) — deep dive

Executive summary: Warp is the VC-funded ($73M) category-definer for the
"agentic development environment," a Rust terminal whose client went
open source (AGPLv3 + MIT UI crates) in April 2026 while its Oz agent
cloud stays proprietary; Windows shipped February 2025 on a forked
ConPTY with PowerShell/WSL/Git Bash but no cmd.exe. Its gravitational
pull on the category is real — blocks, agent mode, hosted CLI agents,
team-shared workflows — but its Windows build carries a non-native
chrome tax (winit/wgpu), memory-leak and GPU-driver crash themes, WSL
gaps, forced auto-update, and a trust deficit (login/telemetry history,
AI pricing whiplash) that the keyboard-first Windows developer
repeatedly cites as reasons to stay away. The sharpest lessons for
winghostty: the workflow objects (named layouts, saved commands, quake
window, restored scrollback) are worth stealing; the cloud coupling,
input-editor takeover, and update coercion are worth loudly not doing.

## 1. Identity & strategy

- Founded June 2020 by Zach Lloyd (ex-Google Principal Engineer);
  funding: $6M seed (GV), $17M Series A (led by Figma's Dylan Field),
  $50M Series B (Sequoia, June 2023); angels include Sam Altman and
  Marc Benioff ([Wikipedia](https://en.wikipedia.org/wiki/Warp_(terminal))).
- Positioning has migrated from "modern terminal" → "AI terminal" →
  "the Agentic Development Environment" (Warp 2.0, June 2025), bundling
  Code, Agents, Terminal, and Drive
  ([Warp 2025 in review](https://www.warp.dev/blog/2025-in-review)).
- Windows launched 2025-02-26 with PowerShell, WSL, Git Bash, x64 and
  ARM64 ([launch post](https://www.warp.dev/blog/launching-warp-on-windows)).
- Client open-sourced 2026-04-28: `warpui_core`/`warpui` crates MIT,
  everything else AGPLv3; OpenAI is "founding sponsor" of the repo and
  contributions are expected to route through Warp's proprietary Oz
  cloud agent orchestrator — the server-side brain is NOT open
  ([announcement](https://www.warp.dev/blog/warp-is-now-open-source),
  [repo](https://github.com/warpdotdev/warp),
  [The New Stack analysis](https://thenewstack.io/warp-open-source-client/)).
  ~64k stars / 5.4k forks by mid-2026 (repo page).
- Governance/bus factor: single company, closed backend, agent-first
  triage. License mix (AGPL + proprietary cloud) drew "open source or
  automation theater?" skepticism on HN
  ([byteiota roundup](https://byteiota.com/warp-terminal-open-source-agentic-dev-environment/)).
- Pricing (post-Dec-2025): terminal free forever; AI metered. Legacy
  Pro/Turbo/Lightspeed replaced by one Build plan, $20/mo with 1,500
  credits; rollover Reload credits; BYOK (OpenAI/Anthropic/Google keys)
  on paid plans only; free tier 150 credits/mo for two months then 75;
  Business $50/user/mo
  ([pricing post](https://www.warp.dev/blog/warp-new-pricing-flexibility-byok),
  [docs FAQ](https://docs.warp.dev/support-and-community/plans-and-billing/pricing-faqs)).

## 2. Performance & fluidity

- Rust client on `winit` + `wgpu`; Warp says only ~2% of code is
  Windows-specific
  ([Windows eng post](https://www.warp.dev/blog/building-warp-on-windows)).
- Warp's own published benchmarks (macOS only, vs Terminal.app, iTerm2,
  Alacritty, WezTerm) show strong scrolling times but poor raw
  throughput: termbench "small" 20s vs Alacritty 2.9s; "regular" 337s
  vs 45s. They explicitly did not measure input latency
  ([docs benchmark page](https://docs.warp.dev/terminal/comparisons/performance/)).
- Third-party 2026 comparisons claim ~8ms key latency vs Ghostty ~2ms
  and 300MB+ idle memory, but these come from low-credibility SEO/AI
  content sites (devtoolswatch, lushbinary) — treat as directional,
  not measured fact. **Uncertain.**
- Memory is a genuine, documented weak point: repeated leak reports,
  including 30GiB while hosting Claude Code/Codex
  ([#8569](https://github.com/warpdotdev/Warp/issues/8569)), a
  Windows-specific idle WSL-respawn loop driving RAM to ~99%
  ([#8822](https://github.com/warpdotdev/Warp/issues/8822)), and an
  extreme "113GB in 33 minutes" report
  ([#7892](https://github.com/warpdotdev/warp/issues/7892)).
- Windows rendering stability depends on GPU driver roulette: crashes
  on startup / failure to render with recent Nvidia 572.xx and AMD
  drivers; the documented workaround is switching graphics backend
  (Vulkan/OpenGL) or forcing the iGPU in settings
  ([known issues](https://docs.warp.dev/support-and-community/troubleshooting-and-support/known-issues/)).
- No published startup-time numbers found. **Uncertain**, but the app
  is an order of magnitude heavier than minimal terminals by design
  (SQLite session DB, AI runtime, block model).

## 3. Native Windows integration

- Chrome is fully custom-drawn (winit), not DWM-native. Consequences
  visible in the tracker: double-click-titlebar maximize broken
  ([#8375](https://github.com/warpdotdev/Warp/issues/8375)), too-small
  drag area ([#5749](https://github.com/warpdotdev/warp/issues/5749)).
  winit itself cannot return `HTMAXBUTTON` from `WM_NCHITTEST`, which
  is what Snap Layouts hover needs with custom titlebars
  ([winit #3884](https://github.com/rust-windowing/winit/issues/3884));
  whether Warp patched around this is unverified — **uncertain**, but
  no doc or issue found showing Snap Layouts hover works.
- Cannot register as the Windows *default terminal application*
  (unlike Windows Terminal); open feature request
  ([#6261](https://github.com/warpdotdev/warp/issues/6261)).
- PTY: Warp forked ConPTY (maintained at
  [warpdotdev/microsoft-terminal](https://github.com/warpdotdev/microsoft-terminal))
  to fix three blockers for its blocks model: ConPTY filtering unknown
  DCS sequences, OSC reordering relative to output, and ConPTY's own
  cached grid state (solved with a custom "Reset" OSC)
  ([eng post](https://www.warp.dev/blog/building-warp-on-windows)).
  This is the single most technically instructive artifact of the
  Windows port.
- Shells: default pwsh 7; PowerShell 5, WSL2, Git Bash supported;
  **cmd.exe not supported**; fish-on-Windows unsupported
  ([supported shells](https://docs.warp.dev/getting-started/supported-shells),
  [known issues](https://docs.warp.dev/support-and-community/troubleshooting-and-support/known-issues/)).
- WSL story is real but rough: AI/codebase-context features don't work
  inside WSL sessions
  ([#6744](https://github.com/warpdotdev/Warp/issues/6744)), WSL tabs
  stuck at "Starting bash" with newer WSL prereleases
  ([#13308](https://github.com/warpdotdev/warp/issues/13308)), WSL
  profile sometimes launches pwsh instead
  ([#7576](https://github.com/warpdotdev/warp/issues/7576)).
- Input plumbing gaps: keyboard entirely dead over RDP
  ([#10567](https://github.com/warpdotdev/warp/issues/10567)), IME
  problems for CJK ([#6891](https://github.com/warpdotdev/warp/issues/6891)),
  keybindings tied to active input source
  ([#341](https://github.com/warpdotdev/Warp/issues/341)).
- Requires Windows 10 1903+ (ConPTY dependency); x64 + ARM64 installers
  ([install docs](https://docs.warp.dev/getting-started/quickstart/installation-and-setup)).
- No evidence found of jump lists, taskbar progress, or Windows
  notification integration.

## 4. Terminal capability

- Core emulation derives from Alacritty's model (credited dependency in
  the repo README) plus Warp's block segmentation. VT conformance is
  adequate for mainstream TUIs but not a stated goal; no conformance
  documentation published. **Uncertain** on edge-case depth.
- Graphics: Kitty image protocol shipped in 2025
  ([2025 in review](https://www.warp.dev/blog/2025-in-review)); sixel
  remains an unfulfilled request
  ([#4593](https://github.com/warpdotdev/Warp/issues/4593)).
- Blocks require Warp's custom bidirectional DCS-based shell
  integration protocol — the reason for the ConPTY fork. Side effect:
  documented conflicts with fzf, Starship, oh-my-zsh/bash/fish plugins,
  and iTerm2 shell integration
  ([known issues](https://docs.warp.dev/support-and-community/troubleshooting-and-support/known-issues/)).
- Warp replaces the shell's own line editor with its IDE-style input
  editor (selection, multi-cursor, optional vim bindings:
  [input editor vim docs](https://docs.warp.dev/terminal/editor/vim/)).
  Power users experience this as breakage of PSReadLine/readline
  muscle memory and of tools that own the prompt.
- ligatures and full UI zoom landed only in 2025 (ibid.) — years after
  peers.
- Scrollback/search exist but per-block; no evidence of regex search
  parity with classic terminals. **Uncertain.**

## 5. Workflow features

- Blocks: each command+output is a discrete unit — navigate by
  keyboard, copy command/output separately, share as permalink. This is
  Warp's defining UX and the category's loudest export.
- Agent surface (the strategic center): built-in Agent Mode; hosted
  external CLI agents (Claude Code, Codex, Gemini CLI) as first-class
  sessions; Oz cloud agents reacting to Slack/Linear/GitHub-Actions
  events; MCP server support; claims of Terminal-Bench 61.2% and
  SWE-bench Verified 75.6%
  ([2025 in review](https://www.warp.dev/blog/2025-in-review),
  [repo](https://github.com/warpdotdev/warp)).
- Warp Drive: shared Workflows (parameterized commands), Notebooks
  (runnable runbooks), Prompts, Rules, env vars, with team RBAC
  ([Drive](https://www.warp.dev/drive),
  [teams docs](https://docs.warp.dev/knowledge-and-collaboration/teams/)).
- Session restoration on by default: windows/tabs/panes plus *recent
  blocks* (scrollback content) persisted in a per-user SQLite DB
  (`%LOCALAPPDATA%\warp\Warp\data\warp.sqlite` on Windows)
  ([session restoration docs](https://docs.warp.dev/terminal/sessions/session-restoration)).
- Declarative layouts: Tab Configs (TOML) and legacy Launch
  Configurations for named multi-tab/pane setups
  ([launch configs](https://docs.warp.dev/terminal/sessions/launch-configurations/)).
- Global hotkey with dedicated quake-style window works on Windows
  (position/size ratio configurable), though autohide-on-focus-loss is
  mac-only ([global hotkey docs](https://docs.warp.dev/terminal/windows/global-hotkey/)).
- Command palette / command search, theme browser, shell selector with
  per-shell tab icons.
- Keyboard-first gaps persist: years-long mega-threads for custom
  keybindings/vim/leader keys
  ([#579](https://github.com/warpdotdev/Warp/issues/579)), tmux
  interop friction ([#3737](https://github.com/warpdotdev/Warp/issues/3737)),
  and a 2026 catalog of keyboard-workflow holes in the IDE surface
  ([#10190](https://github.com/warpdotdev/warp/issues/10190)).

## 6. Reliability & quality signals

- Dominant tracker themes: memory leaks (especially when hosting AI
  CLIs), Windows GPU/driver crashes, WSL bootstrap failures, update
  behavior, shell-integration conflicts (links above).
- Warp reports closing 940 GitHub issues in 2025 against a merged
  10,000+ internal PRs ([2025 in review](https://www.warp.dev/blog/2025-in-review));
  the public issue backlog remains large (15k+ issue numbers).
- Auto-update is effectively mandatory: ~10-minute polling, background
  multi-hundred-MB downloads, silent install on next launch, and no
  runtime off-switch — a consolidated request for a toggle is open
  ([#11058](https://github.com/warpdotdev/warp/issues/11058), earlier
  [#5521](https://github.com/warpdotdev/Warp/issues/5521),
  [#4526](https://github.com/warpdotdev/Warp/issues/4526)). Regulated
  and air-gapped environments call this out explicitly.
- CI/test story externally unverifiable before April 2026; the open
  repo now shows an agent-managed workflow ("ready-to-spec" /
  "ready-to-implement" labels, AGENTS.md). **Uncertain** depth.

## 7. Configuration & extensibility

- GUI-first settings; state in SQLite + some `settings.toml`/YAML
  surfaces (themes are YAML; Tab Configs TOML). No single plain-text
  config contract like Ghostty's; no live-reload-from-file model.
- Custom keybindings exist via GUI editor; vim bindings limited to
  defaults in the code editor
  ([code editor vim docs](https://docs.warp.dev/code/code-editor/code-editor-vim-keybindings/)).
- Extensibility is aimed at the AI layer, not the terminal: MCP
  servers, Rules, BYOK. No terminal plugin/scripting API.
- Theming: built-in + custom YAML themes, theme browser.

## 8. Packaging & adoption

- Windows: bundled installer + `winget install Warp.Warp`
  ([winstall](https://winstall.app/apps/Warp.Warp)); x64 and ARM64.
  No Scoop/portable evidence found. Code signing presumed (mainstream
  installer) but unverified. **Uncertain.**
- Update mechanism: self-updater, forced (see §6) — winget is only the
  initial install vector.
- Docs site (docs.warp.dev) is polished and includes a dedicated
  [Windows Terminal migration guide](https://docs.warp.dev/getting-started/migrate-to-warp/migrate-to-warp-from-windows-terminal/)
  — a deliberate adoption lever.
- Onboarding friction is historically the story: login was mandatory
  until Nov 2024 ([lifting the login requirement](https://www.warp.dev/blog/lifting-login-requirement),
  [HN thread](https://news.ycombinator.com/item?id=42218971)); today
  the terminal works logged-out, but all AI requires an account, and
  telemetry is opt-out, not opt-in
  ([itsfoss coverage](https://itsfoss.com/news/warp-terminal-no-login/)).
- Momentum: 64k+ stars within weeks of open-sourcing; positive
  Windows-press coverage (e.g.
  [The New Stack review](https://thenewstack.io/developer-review-of-warp-for-windows-an-ai-terminal-app/),
  [4sysops](https://4sysops.com/archives/warp-for-windows-finally-ai-powered-automation-for-the-powershell-cli/)).

## 9. What users complain about

- **Trust**: years of "why does a terminal need login/telemetry"
  ([HN 2022](https://news.ycombinator.com/item?id=33629176),
  [issue #900](https://github.com/warpdotdev/Warp/issues/900),
  [HN "no more login required"](https://news.ycombinator.com/item?id=42247583) —
  where many replies remain "still won't touch it"). A 2026 HN thread
  still asks for confirmation Warp makes no network connections
  ([HN](https://news.ycombinator.com/item?id=47945823)).
- **Pricing whiplash**: three paid tiers deprecated inside a year;
  credit metering resented; "over half will pay less" messaging did not
  quiet it ([tessl.io analysis](https://tessl.io/blog/warp-joins-the-pricing-pivot-sweeping-ai-devtools/),
  [transition guide](https://dev.to/thelazyindiantechie/understanding-warps-new-pricing-your-complete-transition-guide-j3o)).
- **AI bloat / identity drift**: HN split between "credible ADE" and
  "VC-backed terminal wrapping AI into a bloated surface"
  ([byteiota](https://byteiota.com/warp-terminal-open-source-agentic-dev-environment/)).
- **Forced auto-update** (§6 links) — top ask from ops/regulated users.
- **Memory leaks** (§2 links) — recurring, cross-platform, worst when
  hosting other AI CLIs.
- **Keyboard-first gaps**: custom keybindings/vim/tmux threads among
  the oldest and most-upvoted issues (§5 links).
- **Windows specifics**: cmd.exe unsupported, WSL AI-context gap, WSL
  session bugs, RDP input dead, driver crashes, can't be default
  terminal (§3 links).
- **Shell-tool conflicts**: fzf/Starship/oh-my-* incompatibilities from
  the block/input-editor takeover (§4 link).

## 10. Lessons for winghostty

### Does well (adopt-candidates)

1. **Quake-style global-hotkey window.** Warp ships a configurable
   dedicated dropdown window on Windows; winghostty has nothing in
   this category (status.md lists no quick terminal). High-value for
   the keyboard-first benchmark user.
2. **Named, declarative session layouts** (Tab Configs / launch
   configurations): winghostty restores the *last* layout implicitly
   but has no way to define and launch a named multi-tab/split
   workspace on demand.
3. **Scrollback content in session restore.** Warp restores recent
   blocks (output) via SQLite; winghostty explicitly restores layout
   only, not contents. Even restoring the last N lines per pane would
   close a felt gap.
4. **Block-derived navigation verbs without blocks.** winghostty
   already has OSC 133 prompt marks + PowerShell integration; add
   jump-to-previous-command, copy-last-output, and re-run-command
   actions in the universal palette — 80% of blocks' daily value with
   0% of the ConPTY-fork cost.
5. **A "migrate from Windows Terminal" doc.** Cheap, deliberate
   adoption lever Warp executes well.
6. **Being a great host for CLI agents.** Warp's Claude Code/Codex
   hosting leaks memory; a terminal that runs agent TUIs flawlessly
   (throughput, scrollback, no interception) is a real differentiator
   winghostty already almost has — but should test and claim.

### Does badly (avoid / exploit)

1. **Cloud coupling & trust deficit**: login-for-AI, opt-out
   telemetry, closed Oz backend. winghostty's local-only crash dumps
   and no-upload code path are a marketable opposite — say it loudly.
2. **Forced silent auto-update with no off switch.** winghostty's
   user-initiated, checksum+Authenticode staged updates are exactly the
   policy Warp users beg for; never regress it.
3. **Non-native chrome tax** (winit): broken double-click maximize,
   Snap Layouts doubts, dead RDP input, IME trouble, input-source-bound
   keybindings. winghostty's native Win32 + DWM + IME + UIA work is the
   direct counter; RDP and IME correctness are worth regression tests.
4. **Intercepting the shell**: Warp's input editor and DCS protocol
   fight fzf, Starship, PSReadLine, tmux. winghostty should keep the
   shell's own editor sacred and advertise "your prompt tools just
   work."
5. **Pricing/identity whiplash**: feature surface chased AI runway,
   terminal fundamentals (ligatures, zoom, sixel, cmd.exe) lagged.
   Feature-count restraint is already winghostty's stated principle.
6. **cmd.exe unsupported / WSL bugs**: winghostty's plain-fallback
   cmd.exe support and profile-picker WSL detection already beat Warp
   here; keep WSL launch reliability a tested invariant.

### Blind-spot candidates (no category in PRODUCT.md)

1. **An AI/agent stance.** PRODUCT.md never mentions AI. Even if the
   answer is "no cloud AI ever, best-in-class host for local CLI
   agents," the category's center of gravity demands an explicit
   position (and it doubles as a privacy differentiator).
2. **Reusable command knowledge**: saved parameterized commands,
   snippets, runbooks (Warp Drive Workflows/Notebooks). winghostty's
   palette has "recent commands" but no user-curated library, local or
   shared.
3. **Team/collaboration layer**: shared config/workflows/rules across
   an org. Probably out of scope — but currently unclassifiable in
   PRODUCT.md.
4. **Default-terminal-application registration** (Windows'
   `delegation` API): absent from status.md and the capability matrix;
   Warp can't do it either — first-mover native win available.
5. **Cross-device/settings sync**: Warp syncs Drive objects via
   account; winghostty has no stated position on config portability.
6. **Public benchmark posture**: Warp markets agent benchmarks and
   even publishes (unflattering) terminal benchmarks. winghostty
   claims "fastest, most fluid" with no published latency/throughput
   evidence category.
