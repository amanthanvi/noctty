# Windows Terminal (microsoft/terminal) — deep dive

Researched 2026-08-17. Evidence: repo, devblogs, Microsoft docs, HN/third-party
benchmarks. Uncertainty is marked inline.

**Executive summary (5 lines):**
Windows Terminal is the incumbent every Windows user compares against: MIT-licensed,
inbox/default on Windows 11, ~104.6k stars, maintained by a ~6-person Microsoft team on a
quarterly cadence that has visibly slipped (1.26 delayed, releases paused "for reliability
and performance"). Its strengths are OS integration nobody else can match (default-terminal
handoff, taskbar progress, quake mode, elevation model) and a now-fast AtlasEngine + 1.22
ConPTY rewrite; its chronic weaknesses are input latency (~2x conhost), slow XAML startup,
a sprawling dual JSON/UI settings system, 1.6k open issues, no session _content_ philosophy
beyond plain-text buffer snapshots, and no plugin/scripting model. Sixel shipped in 1.22 and
the Kitty _keyboard_ protocol in 1.25, but Kitty _graphics_ remains an open request — the
capability gap winghostty already fills. The exploitable space is exactly what PRODUCT.md
targets: instantaneous native feel, dependable session restore, and deep terminal capability.

---

## 1. Identity & strategy

- What it is: Microsoft's official modern terminal for Windows, sharing a repo with the
  legacy console host (conhost.exe) and ConPTY. MIT license.
  ([repo](https://github.com/microsoft/terminal))
- Ships two channels (Stable, Preview) plus nightly Canary (App Installer on Win11,
  portable ZIP on Win10/11). Inbox and **default terminal on Windows 11 since 22H2**; it is
  the reference against which "a Windows terminal" is judged.
- Governance/bus factor: a small named Microsoft core team — Christopher Nguyen (PM),
  Dustin Howett (eng lead), Mike Griese, Carlos Zamora, Pankaj Bhojwani, Leonard Hecker
  ([README](https://github.com/microsoft/terminal)). Roadmap is explicitly informal: the
  ["Core team North Stars" wiki](https://github.com/microsoft/terminal/wiki/Core-team-North-Stars)
  calls its items "gut feelings, rather than definitive assigned tasks."
- Strategy signals 2025–2026: pause of the quarterly cycle "to focus on reliability and
  performance" before 1.25
  ([1.25 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-25-release/));
  1.26 delayed with no ETA, gap filled by servicing releases
  ([ntcompatible](https://www.ntcompatible.com/story/windows-terminal-124-and-125-update-released-bug-fixes-and-v126-delay/)).
  AI investment: experimental "Terminal Chat" (GitHub Copilot / Azure OpenAI / OpenAI) in
  Canary, free Copilot tier since Feb 2025
  ([MS docs](https://learn.microsoft.com/en-us/windows/terminal/terminal-chat),
  [GitHub changelog](https://github.blog/changelog/2025-02-26-github-copilot-now-available-for-free-in-windows-terminal-canary/)).
- Relationship to upstream: _is_ the upstream for the Windows console stack — every other
  Windows terminal (including winghostty) sits on its ConPTY.

## 2. Performance & fluidity

- Rendering: AtlasEngine — DirectWrite/Direct2D only rasterizes glyphs into a texture
  atlas; placement/blending is Direct3D 11 + HLSL, with a D2D fallback for weak GPUs
  ([PR #11623](https://github.com/microsoft/terminal/pull/11623),
  [DeepWiki rendering overview](https://deepwiki.com/microsoft/terminal/3-rendering-system)).
  History matters: the 2021 refterm/Casey Muratori "kerfuffle" forced the rewrite; the team
  publicly admitted "we were wrong" about DirectWrite being fast enough
  ([Visual Studio Magazine](https://visualstudiomagazine.com/articles/2022/02/07/windows-terminal-1-13.aspx)).
  AtlasEngine has been the default for years; known cost: frame rate can drop below refresh
  when fighting the buffer lock
  ([discussion #12811](https://github.com/microsoft/terminal/discussions/12811)).
- Throughput: the 1.22 ConPTY rewrite ("new hosting subsystem replaces ConPTY v1") claimed
  "2x the I/O speed for VT heavy workloads, up to 16x for plaintext"
  ([1.22 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-22-release/)).
  1.25 added profile-guided optimization for another claimed 10–20% I/O throughput
  ([1.25 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-25-release/)).
- Latency: Chad Austin's 240 Hz camera measurements (2024, WT 1.18-era) put WT at ~66.7 ms
  keypress-to-pixels vs 33.3 ms for conhost/MinTTY — roughly 2x — and measured **60x CPU
  and 10x RAM vs conhost** when focused
  ([chadaustin.me](https://chadaustin.me/2024/02/windows-terminal-latency/)). The Nov 2025
  HN re-run of that article acknowledges 1.19/1.22 halved-latency and throughput fixes but
  commenters still cite ~32 ms input latency and GPU-pipeline quirks
  ([HN #45890726](https://news.ycombinator.com/item?id=45890726)). Uncertain: no published
  post-1.22 camera-methodology numbers found.
- Startup: chronic complaint since 2020 (multi-second cold starts, "DesktopWindowXamlSource"
  placeholder window) — [#4886](https://github.com/microsoft/terminal/issues/4886) (closed
  as duplicate; the underlying XAML-Islands/MSIX cold-start cost persists in newer reports,
  e.g. [#9905](https://github.com/microsoft/terminal/issues/9905)). No published startup
  benchmark from the team. Uncertain how much recent servicing improved this; complaints
  continued into late 2025.
- 1.24 stable shipped DECSET 2026 "Synchronized Output" for tear-free TUI updates
  ([1.25 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-25-release/)).

## 3. Native Windows integration

The strongest section — this is what "table stakes" means to a Windows user:

- **Default terminal registration**: WT owns the OS-level default-terminal handoff; console
  apps launched anywhere open in it. Inbox on Windows 11.
- **Elevation model**: deliberate security decision — no mixed-elevation tabs in one
  window; elevated profiles open a separate elevated window
  ([FAQ](https://learn.microsoft.com/en-us/windows/terminal/faq)).
- **Taskbar progress**: ConEmu-style OSC 9;4 renders progress in the taskbar button
  ([MS docs](https://learn.microsoft.com/en-us/windows/terminal/tutorials/progress-bar-sequences)).
- **Quake mode + global summon**: Win+` global hotkey, top-half slide-down window, tray
  icon; rebuilt on a "completely new and more reliable windowing architecture" in 1.23
  ([1.23 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-23-release/),
  [megathread #8888](https://github.com/microsoft/terminal/issues/8888)).
- ARM64: native builds; ships on ARM Windows 11.
- WSL: first-class profile auto-detection; 1.24 preview added SSH profile auto-detection
  ([alternativeto news](https://alternativeto.net/news/2025/8/windows-terminal-1-24-preview-adds-new-windowing-system-ui-customization-ssh-profiles)).
- ConPTY: it _owns_ ConPTY, so it benefits first from every ConPTY fix (the 1.22 rewrite);
  third-party terminals inherit the interface later via Windows servicing. Passthrough mode
  ([#1173](https://github.com/microsoft/terminal/issues/1173)) is still not shipped —
  a chronic ecosystem-wide ceiling.
- Chrome: WinUI/XAML tabs, Mica/acrylic backdrops, theme-aware title bar; Snap Layouts and
  jump lists work as for any packaged Win32/XAML app (jump-list profile entries supported;
  uncertain on fine details, low load-bearing).

## 4. Terminal capability

- VT conformance: historically mid-tier, improving steadily. 1.22 added grapheme-cluster
  handling and regex search; 1.24 added Synchronized Output (mode 2026); **1.25 added the
  Kitty keyboard protocol**
  ([1.25 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-25-release/)).
- Graphics: **Sixel shipped in 1.22 preview / 1.23 stable**
  ([1.22 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-22-release/));
  memory-allocation fixes still landing in 1.25
  ([releases](https://github.com/microsoft/terminal/releases)). Note
  [arewesixelyet.com](https://www.arewesixelyet.com/) still lists WT "unsupported" — stale.
  **Kitty graphics protocol: open request, unimplemented**
  ([#8389](https://github.com/microsoft/terminal/issues/8389)). iTerm2 inline images: not
  supported (uncertain: no signal of plans).
- Hyperlinks (OSC 8): supported; 1.24/1.25 added URL-safety warning dialog and
  `safeUriSchemes` ([releases](https://github.com/microsoft/terminal/releases)).
- Shell integration: OSC 133 prompt marks with `showMarksOnScrollbar`, `autoMarkPrompts`,
  scroll-to-mark navigation — de-experimentalized in 1.21
  ([MS tutorial](https://learn.microsoft.com/en-us/windows/terminal/tutorials/shell-integration)).
  "Finishing marks" and "gutter buttons like VS Code" remain North-Star items, i.e.
  unfinished ([North Stars](https://github.com/microsoft/terminal/wiki/Core-team-North-Stars)).
- Search: regex search since 1.22. Scrollback: fixed-size per-profile history; buffer
  snapshot restore (see §5). Quick Fix / winget suggestions for unknown commands in cmd
  (1.22).

## 5. Workflow features

- Tabs, panes (splits), **tab tear-out and cross-window tab drag** shipped via "Process
  Model v3" ([#14957](https://github.com/microsoft/terminal/issues/14957)); still shedding
  bugs — panes dropped on tear-off fixed in 1.23, tab-drag crash fixed as late as July 2026
  ([releases](https://github.com/microsoft/terminal/releases),
  [#18572](https://github.com/microsoft/terminal/issues/18572)).
- Command palette (Ctrl+Shift+P), incl. cross-language English-keyword matching (1.24).
- **Session restore**: `firstWindowPreference: persistedWindowLayout` restores windows/
  tabs/panes; 1.21 added **buffer content snapshots** (`buffer_<guid>.txt` under
  LocalState) so previous output text reappears at startup
  ([#961](https://github.com/microsoft/terminal/issues/961),
  [4sysops](https://4sysops.com/archives/new-in-windows-terminal-restore-buffers-code-snippets-scratchpad-and-regex/)).
  Rollout was rough: restore-crash and scrollback-pollution bugs
  ([#16995](https://github.com/microsoft/terminal/issues/16995),
  [#17274](https://github.com/microsoft/terminal/issues/17274)). Restores text only — no
  processes, cwd via shell integration only.
- **Broadcast input** to all panes in a tab (`toggleBroadcastInput`, 1.19) with accent-color
  pane highlighting ([1.19 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-19-release/));
  per-pane selection still requested ([#17011](https://github.com/microsoft/terminal/issues/17011)).
- Snippets pane (saved commands) + scratchpad pane (1.22); profiles with folders/nesting
  and a New Tab Menu editor (1.23); Quake mode (§3).
- Keybinding model: JSON actions; 1.25 finally added a rich **actions editor UI**
  ([1.25 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-25-release/)).

## 6. Reliability & quality signals

- ~1.6k open issues, 88 open PRs ([repo](https://github.com/microsoft/terminal)). Dominant
  themes: startup time, latency/perf regressions, tear-out/windowing bugs, settings-UI vs
  JSON friction, rendering edge cases (font fallback, DRCS memory corruption fixed July
  2026), NVIDIA driver deadlock (fixed July 2026)
  ([releases](https://github.com/microsoft/terminal/releases)).
- The team's own framing is telling: pausing feature releases "to focus on reliability and
  performance" (1.25 blog), then delaying 1.26 with interim servicing builds — a mature
  product spending its cycles on stabilization, not new capability.
- Release stability reputation: preview channel catches a lot; stable is broadly trusted
  (inbox distribution forces it), but flagship features (buffer restore, tear-out) shipped
  with months of follow-on crash fixes (§5 citations).
- CI/test: extensive unit/feature test suites in-repo; Accessibility Insights in CI is a
  North-Star goal (not fully realized)
  ([North Stars](https://github.com/microsoft/terminal/wiki/Core-team-North-Stars)).

## 7. Configuration & extensibility

- Dual model: `settings.json` (live-reloaded) + WinUI settings UI that writes back to the
  JSON. Chronic friction: the UI reformats/reorders user JSON
  ([#8991](https://github.com/microsoft/terminal/issues/8991)), some settings are
  UI-only-discoverable while others are JSON-only; users who want GUI-only were vocal for
  years ([#7326](https://github.com/microsoft/terminal/issues/7326)). 1.23–1.25 poured
  effort into closing the gap (icon picker, compatibility page, settings search).
- Theming: color schemes incl. VS Code scheme import (1.25); per-profile appearance;
  fragments let apps inject profiles/schemes.
- Extensibility: **no plugin or scripting API.** "Extensions" (1.24 settings page) are JSON
  fragment extensions — profiles, schemes, actions only
  ([1.25 blog](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-25-release/)).
  "What does an extension model look like?" is literally an open North-Star question.
  No socket/CLI automation surface comparable to wezterm/kitty remote control.

## 8. Packaging & adoption

- Channels: Microsoft Store (recommended, auto-update), GitHub `.msixbundle`, winget
  (`Microsoft.WindowsTerminal`), unofficial Chocolatey/Scoop, Canary App Installer +
  portable ZIP ([README](https://github.com/microsoft/terminal)). Inbox on Windows 11 =
  zero-friction adoption; signed by Microsoft; docs on learn.microsoft.com are polished and
  localized.
- Momentum: 104.6k stars, 9.5k forks; cadence formally quarterly but effectively slower —
  1.22 (late 2024) → 1.23/1.24 (2025) → 1.25 (Mar 2026) → 1.26 delayed, servicing builds
  July 2026 ([releases](https://github.com/microsoft/terminal/releases),
  [ntcompatible](https://www.ntcompatible.com/story/windows-terminal-124-and-125-update-released-bug-fixes-and-v126-delay/)).
- MSIX cost: packaging contributes to cold-start and makes true portable/self-contained use
  a Canary-only afterthought (uncertain attribution of exact startup share, widely claimed
  in issues).

## 9. What users complain about

Recurring, sourced themes:

1. **Startup lag / perceived heaviness** — multi-second cold start, frozen first window
   ([#4886](https://github.com/microsoft/terminal/issues/4886),
   [#9905](https://github.com/microsoft/terminal/issues/9905)); "60x CPU / 10x RAM vs
   conhost" ([chadaustin.me](https://chadaustin.me/2024/02/windows-terminal-latency/)).
2. **Input latency** — "input is as slow as rubber cement"
   ([#11916](https://github.com/microsoft/terminal/issues/11916)); ~2x conhost latency in
   measured tests; still raised on HN in Nov 2025
   ([HN #45890726](https://news.ycombinator.com/item?id=45890726)).
3. **Settings sprawl and JSON/UI split** — UI rewrites user JSON
   ([#8991](https://github.com/microsoft/terminal/issues/8991)), settings scattered across
   UI/JSON/defaults.json; the fact that 1.25's headline feature is _search inside settings_
   is the tell.
4. **Windowing/tear-out fragility** — megathread of drag/drop gaps
   ([#14900](https://github.com/microsoft/terminal/issues/14900)), crashes into mid-2026.
5. **Session restore is shallow** — text-only snapshots, restore bugs
   ([#17274](https://github.com/microsoft/terminal/issues/17274),
   [#16995](https://github.com/microsoft/terminal/issues/16995)).
6. **ConPTY ceilings** — passthrough never shipped
   ([#1173](https://github.com/microsoft/terminal/issues/1173)); ordering/truncation bugs
   ([#8698](https://github.com/microsoft/terminal/issues/8698),
   [#4116](https://github.com/microsoft/terminal/issues/4116)).
7. Elevation friction — separate windows for admin (defensible, but users complain; gsudo
   exists as workaround
   ([FAQ](https://learn.microsoft.com/en-us/windows/terminal/faq))).

## 10. Lessons for winghostty

### Does well (adopt-candidates — winghostty measurably lacks these)

1. **Quake mode / global summon with tray icon** — WT's most-loved workflow feature
   (megathread [#8888](https://github.com/microsoft/terminal/issues/8888)); winghostty's
   status.md has no dropdown/global-hotkey surface. Upstream Ghostty has quick terminal on
   macOS; a Win32-native, pre-warmed quake window is a direct adopt.
2. **Taskbar progress via OSC 9;4** — cheap, visible, native; matches PRODUCT.md's
   "progress visible without noise." Not in winghostty's capability matrix.
3. **Buffer-content restore** — WT restores previous output text at startup; winghostty's
   `window-save-state` explicitly does not restore contents. Even WT's flawed plain-text
   snapshot beats nothing for the benchmark user.
4. **Default-terminal registration** — WT owns the OS handoff; winghostty should register
   as a selectable default terminal app (Windows 11 supports third-party registration —
   this is how a terminal becomes _the_ terminal).
5. **Jump lists / SSH + profile auto-detection breadth** — WT auto-detects SSH hosts
   (1.24 preview) and exposes profiles in the taskbar jump list; winghostty detects shells
   only.
6. **Kitty keyboard protocol** (WT 1.25) — verify winghostty inherits this from Ghostty
   core and validate it on Win32 input path; if not validated, it's now table stakes.
7. **URL-safety prompt** (`safeUriSchemes`, 1.25) — a small trust feature aligned with
   winghostty's privacy posture.
8. **Elevation-aware UX** — a deliberate, documented elevation model (even if different
   from WT's separate-window rule); winghostty docs are silent on running elevated.

### Does badly (avoid / exploit)

1. **Startup weight** — XAML/MSIX cold start is a structural cost of its architecture;
   winghostty's native Win32 + OpenGL stack should make sub-100ms cold start a headline,
   _measured and published_ (WT publishes no startup numbers — a vacuum to occupy).
2. **Input latency** — 2x conhost, GPU-pipeline latency largely unaddressed for years.
   Publish camera-methodology latency benchmarks; PRODUCT.md's "instantaneous" claim needs
   numbers to beat the incumbent credibly.
3. **Settings sprawl** — WT needed a search engine for its own settings; winghostty's
   staged, source-preserving settings window that _never rewrites unrelated JSON_ is the
   direct answer to [#8991](https://github.com/microsoft/terminal/issues/8991) — market it
   as such.
4. **Feature-first, stabilize-later releases** — buffer restore and tear-out each shipped
   then crashed for months. winghostty's undo/redo-transactional structural model is the
   differentiator; keep flagship features behind reliability gates.
5. **Graphics gap** — WT has Sixel only; Kitty graphics is an open issue
   ([#8389](https://github.com/microsoft/terminal/issues/8389)). winghostty already ships
   Kitty graphics — this is a concrete "deep terminal capability" wedge; validate + demo it
   on Windows (TUIs: yazi, chafa, notcurses).
6. **No extensibility story** — a decade-old product still asking "what does an extension
   model look like?" winghostty's allowlisted `+perform-action` IPC is a seed; a documented
   automation surface (wezterm-cli-style) exploits WT's vacuum without becoming a plugin
   platform.
7. **Session restore depth** — WT restores text; nobody on Windows restores _working
   state_ well. winghostty restoring layout+profile+cwd reliably, plus optional content
   snapshots, leapfrogs rather than matches.

### Blind-spot candidates (no category in winghostty PRODUCT.md)

1. **AI-in-terminal** — Terminal Chat/Copilot is Microsoft's differentiating bet; PRODUCT.md
   has no position on AI assistance (even "explicitly out of scope" is a position worth
   writing down).
2. **Quake/dropdown terminal as a product surface** — PRODUCT.md's workflow list (tabs,
   splits, search, restore) has no category for summon-from-anywhere terminal access.
3. **Elevation/UAC as a designed surface** — mixed-elevation policy, elevated-profile UX,
   and the security boundary story are absent from winghostty docs.
4. **Snippets/saved-commands and non-terminal panes** (scratchpad) — WT treats "remembering
   commands" as a first-class emergency workflow; winghostty's palette has recent commands
   but no persistent snippet store.
5. **Inbox/OS distribution & default-terminal politics** — competing against a preinstalled
   default is a go-to-market problem PRODUCT.md never names: winghostty must articulate why
   someone replaces the default, not just how it differs.
6. **Localization** — WT ships community translations (Serbian, Ukrainian in 1.25) and
   cross-language command-palette matching; winghostty docs never mention non-English users.
7. **Progress/notification OS surfaces beyond the window** (taskbar, tray, toasts) — WT
   treats the Windows shell itself as part of the terminal UX; winghostty's design frame
   stops at the window edge.
