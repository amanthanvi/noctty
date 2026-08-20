# Rio (raphamorim/rio) — deep dive

Executive summary (5 lines): Rio is a Rust terminal that made an early "WebGPU
everywhere" bet and has since partially walked it back — native Metal/Vulkan
backends on macOS/Linux, with Windows still riding the wgpu translation layer
(DX12/DX11). Its velocity is extreme (16 releases in the first half of August
2026, ~97% of commits by one person), it has real Windows binaries (MSI,
portable, x64+ARM64, winget/choco/scoop), and it just spun its engine out as
embeddable `rio-vt`/`librio` crates plus a WASM/npm web build. But Windows is
visibly the third platform: unsigned installers, open startup-crash/opacity/
paste bugs, manual `conpty.dll` sideloading for image protocols, no WSL story,
no session restore (open request since 2023), no profiles, no palette — so it
does not yet threaten noctty's benchmark user, though its trajectory and
the author's proven ability to ship workflow features (in closed-source
Canario, tellingly) make it the fastest-moving adjacent competitor to watch.

## 1. Identity & strategy

- "A hardware-accelerated GPU terminal emulator focusing to run in desktops
  and browsers" — cross-platform (Windows, macOS, Linux, FreeBSD) plus a
  WebAssembly build; MIT license; created Oct 2022
  ([repo](https://github.com/raphamorim/rio), API metadata retrieved
  2026-08-17).
- Positioning: "modern terminal built to run everywhere," GPU acceleration,
  eye-candy (CRT/RetroArch shaders, blurred backgrounds, cursor trails), and
  since July 2026 an ecosystem play: the engine ships as `rio-vt` (safe Rust
  crate: VT state machine, parser, grid+scrollback, selection, search, PTY,
  sixel/kitty/iTerm2 images) and `librio` (same core behind a C ABI, prebuilt
  static lib) — explicitly pitched as "a modern alternative to
  `alacritty_terminal`"
  ([blog](https://rioterm.com/blog/2026/07/27/rio-vt-and-librio),
  [HN](https://news.ycombinator.com/item?id=49084236)). This directly mirrors
  noctty's retained `libghostty-vt`.
- Governance/bus factor: effectively a single-author project. GitHub commit
  search shows 339 commits on main between 2026-07-01 and 2026-08-17, of
  which 329 are by raphamorim (~97%) (GitHub commit search API, 2026-08-17).
  The author announced joining Charm.sh in Dec 2024
  ([HN item 42449686](https://news.ycombinator.com/item?id=42449686));
  whether that employment persists in 2026 is unverified.
- Strategy signal: Canario, a macOS-only "spaces + command bar + quick
  terminal + session restore" spin-off built on the Rio engine, was announced
  in 2026 and then **closed-sourced** on 2026-08-11 because the author
  "simply do[es]n't have the time to maintain it as an open source project"
  (also citing AI-generated contribution spam)
  ([rioterm.com/canario](https://rioterm.com/canario),
  [rapha.land post](https://rapha.land/closing-canario-terminal-source-code/)).
  I.e., the polished workflow layer is being withheld from the OSS terminal.

## 2. Performance & fluidity

- Renderer ("Sugarloaf"): historically pure wgpu/WebGPU. As of the 0.3–0.5
  era it is *adaptive per platform*: native Metal (macOS) and native Vulkan
  (Linux) backends are the defaults ("smaller and skip the wgpu translation
  layer"), with the wgpu-based WebGPU backend as fallback and as the only
  path that supports RetroArch shader filters
  ([config docs](https://rioterm.com/docs/config)). **Windows has no native
  backend** — it goes through wgpu, which picks DX12/DX11/GL
  ([config docs](https://rioterm.com/docs/config); third-party summary at
  [x-cmd](https://www.x-cmd.com/install/rio/)). The WebGPU bet is thus
  half-abandoned where it hurt (binary size, translation overhead) and kept
  where it pays (web target, shader filters) — but Windows kept the tax.
- Render loop: event-driven by default (`renderer.strategy = Events`) with an
  optional continuous `Game` mode; `target-fps`; `disable-unfocused-render`;
  adapter power preference High/Low
  ([config docs](https://rioterm.com/docs/config)). Third-party description
  of damage tracking ("unchanged lines are not redrawn")
  ([terminal.guide](https://www.terminal.guide/tools/terminal-emulator/rio/))
  — plausible but not verified in code for this dive.
- Throughput: self-reported parser rewrite in 0.5.3 claims plain-text parsing
  2.7x faster (865 → 2340 MiB/s) and CJK/emoji 3x via word-at-a-time
  scanning/bulk UTF-8 decode; the WASM engine claims 3x faster than xterm.js
  on plain text ([changelog](https://rioterm.com/changelog)). **No credible
  independent latency or throughput benchmarks found**; Rio's own "rio-is-fast"
  doc offers no numbers, only "built in Rust" reasoning
  ([docs](https://github.com/raphamorim/rio/blob/main/docs/docs/features/rio-is-fast.md)).
- Windows latency: 0.5.5 fixed a real ConPTY-specific defect — synchronized-
  update timeout handling that delivered typing echo **150–200 ms late** in
  ConPTY TUIs ([changelog](https://rioterm.com/changelog)). Good fix; also
  evidence such artifacts shipped for a while.
- Startup time: no published measurements found (unknown).
- Churn cost of the wgpu dependency: the wgpu 30 upgrade broke macOS 10.15
  linking and needed a 0.5.25 fix ([changelog](https://rioterm.com/changelog)).

## 3. Native Windows integration

- Ships MSI installers and portable exes for x86_64 **and aarch64**; WinGet
  (`raphamorim.rio`), Chocolatey, Scoop, MSYS2
  ([install docs](https://rioterm.com/docs/install/windows)).
- Code signing: apparently none — the official docs tell users to expect a
  security warning and click "Run anyway"
  ([install docs](https://rioterm.com/docs/install/windows)).
- PTY: ConPTY. Image protocols (sixel/iTerm2/kitty) require ConPTY ≥ 1.22
  because in-box ConPTY strips those sequences; Rio's answer is for the user
  to manually place a newer `conpty.dll` + `OpenConsole.exe` next to the exe,
  which Rio auto-loads ([install docs](https://rioterm.com/docs/install/windows)).
  Windows image rendering still has open breakage (Yazi:
  [#1759](https://github.com/raphamorim/rio/issues/1759), sixel:
  [#729](https://github.com/raphamorim/rio/issues/729)).
- Window chrome: config knobs exist (`windows-corner-preference`,
  `windows-use-undecorated-shadow`, `windows-use-no-redirection-bitmap`,
  acrylic blur) ([config docs](https://rioterm.com/docs/config)), but
  opacity is reported broken on Windows 11
  ([#992](https://github.com/raphamorim/rio/issues/992), still open 2026).
- No evidence of: Snap Layouts work, jump lists, taskbar progress, toast
  notifications, default-terminal-app registration, elevation handling, or
  Explorer integration (absence inferred from docs + issue search; low
  uncertainty).
- WSL: no first-class story — no distro picker or docs; a user can point
  `shell` at `wsl.exe`. Open issue about WSL scrollback behavior
  ([#1861](https://github.com/raphamorim/rio/issues/1861)). Default shell on
  Windows is PowerShell ([config docs](https://rioterm.com/docs/config)).
- IME: supported as a headline feature ([features](https://rioterm.com/docs/features)).

## 4. Terminal capability

- Parser lineage: originally Alacritty's VTE; now its own engine (`rio-vt`)
  with grid, scrollback, selection, search
  ([rio-vt blog](https://rioterm.com/blog/2026/07/27/rio-vt-and-librio)).
- Graphics: **all three protocols** — sixel, iTerm2, kitty (incl. virtual
  placements) ([features](https://rioterm.com/docs/features),
  [changelog 0.4.12](https://rioterm.com/changelog)) — though Windows support
  is gated on the ConPTY sideload above and still buggy.
- Kitty keyboard protocol, OSC 8 hyperlinks, hints (keyboard-driven pattern
  capture), vi mode, IME ([features](https://rioterm.com/docs/features)).
- Unicode: opt-in grapheme clustering via DEC mode 2027, Unicode 17 width
  tables in a new `rio-unicode` crate (0.5.20,
  [changelog](https://rioterm.com/changelog)).
- Shell integration: thin. Docs only cover OSC 7/6 cwd reporting with manual
  shell configuration ([docs](https://rioterm.com/docs/features/shell-integration));
  OSC 133 semantic-prompt tracking with `ScrollToPrevPrompt`/`ScrollToNextPrompt`
  actions landed recently ([changelog](https://rioterm.com/changelog)). No
  automatic per-shell injection comparable to Ghostty/noctty.
- Search: exists and lives in the engine, but has regressed before ("Search
  seems broken in 0.2.0", [#785](https://github.com/raphamorim/rio/issues/785));
  vi-mode search was a long-open request
  ([#611](https://github.com/raphamorim/rio/issues/611)).
- Extras: wide color gamut support, RetroArch shader filters, CRT mode,
  cursor trails with spring physics (0.5.25,
  [changelog](https://rioterm.com/changelog)).

## 5. Workflow features

- Tabs: multiple navigation styles (Tab default; historical CollapsedTab/
  Bookmark/TopTab/BottomTab; NativeTab macOS-only; `Plain` mode to defer to
  tmux/zellij) ([config docs](https://rioterm.com/docs/config), search
  corroboration via [x-cmd](https://www.x-cmd.com/install/rio/)).
- Splits: built in, with unfocused-split dimming; users complain split UX
  trails Ghostty/WezTerm (uncontrollable divider styling, bad multi-split
  resizing) ([HN Oct 2025](https://news.ycombinator.com/item?id=45432977)).
- Session restore: **absent**; requested since Oct 2023 and still open
  ([#322](https://github.com/raphamorim/rio/issues/322)). It exists — in
  closed-source Canario instead ([canario](https://rioterm.com/canario)).
- Profiles: absent; open request
  ([#622](https://github.com/raphamorim/rio/issues/622)).
- Command palette / quick terminal: not in Rio (a `ToggleQuake`-style binding
  appears in docs but the polished quick terminal + ⌘K command bar shipped in
  Canario, macOS-only) ([config docs](https://rioterm.com/docs/config),
  [canario](https://rioterm.com/canario)).
- Broadcast input: no evidence (absent).
- Keybindings: TOML `[bindings]` action model; defaults have clashed across
  platforms ([#914](https://github.com/raphamorim/rio/issues/914)); leader-key
  request open since Jan 2024 ([#415](https://github.com/raphamorim/rio/issues/415)).

## 6. Reliability & quality signals

- Open issues: 277 (2026-08-17, GitHub API). Dominant themes: font/glyph
  rendering edge cases, image-protocol breakage, platform window-management
  glitches, Windows-specific input/rendering bugs.
- Windows-specific open bugs (Aug 2026): startup freeze/crash
  ([#1804](https://github.com/raphamorim/rio/issues/1804)), multi-line paste
  corruption ([#1669](https://github.com/raphamorim/rio/issues/1669)),
  fullscreen-close flash ([#1791](https://github.com/raphamorim/rio/issues/1791)),
  user PATH not resolved ([#1790](https://github.com/raphamorim/rio/issues/1790)),
  opacity broken ([#992](https://github.com/raphamorim/rio/issues/992)).
- Regression pattern: rapid-fire releases fix their own breakage — "the
  cursor trail actually works now — five issues traced to animation state
  handling" (0.5.25), resize leaving unpainted areas (0.5.1), search broken
  in 0.2.0, box-drawing "renders again" (0.4.6)
  ([changelog](https://rioterm.com/changelog)). Multiple releases per day in
  August 2026 (0.5.22 and 0.5.23 both on Aug 12;
  [releases](https://github.com/raphamorim/rio/releases)) is a
  ship-then-stabilize cadence, not a stabilization gate.
- Security: hint URLs allowed arbitrary command execution on Windows until
  0.5.10 (fixed via `ShellExecuteW`) ([changelog](https://rioterm.com/changelog));
  Canario deep links needed security fixes shortly after launch (same source).
- HN sentiment (Oct 2025): "Ghostty is superior regarding attention to
  detail"; split behavior, tab zoom inheritance, blur, and character
  rendering all criticized ([HN](https://news.ycombinator.com/item?id=45432977)).

## 7. Configuration & extensibility

- TOML config at `%USERPROFILE%\AppData\Local\rio\config.toml` on Windows;
  automatic live reload on file change; `[platform]` section for per-OS
  overrides ([config docs](https://rioterm.com/docs/config)).
- Theming: adaptive light/dark theme, theme files, background images, wide
  color gamut, RetroArch shaders ([features](https://rioterm.com/docs/features)).
- No GUI settings, no plugin/scripting surface in the app. Extensibility is
  instead the *embedding* direction: `rio-vt` (Rust), `librio` (C ABI), and
  `rioterm` on npm with a React wrapper for the web build
  ([blog](https://rioterm.com/blog/2026/07/27/rio-vt-and-librio),
  [changelog 0.5.20](https://rioterm.com/changelog)).

## 8. Packaging & adoption

- Channels: Windows MSI + portable (x64/ARM64), winget, Chocolatey, Scoop,
  MSYS2; macOS dmg; Linux rpm/deb + distro repos; FreeBSD; npm for the web
  engine ([install docs](https://rioterm.com/docs/install/windows),
  [releases](https://github.com/raphamorim/rio/releases)).
- No built-in updater found (users update via package manager; uncertainty:
  not explicitly documented either way).
- Momentum: 7,372 stars, 329 forks (2026-08-17, GitHub API; ~7.4k shown on
  repo page). Cadence: ~monthly minors through mid-2026, then 16 releases in
  Aug 2026 alone after the 0.5.0 engine split
  ([changelog](https://rioterm.com/changelog)). Docs site (rioterm.com) is
  well-organized with a real changelog and blog; translated docs exist.
- Onboarding friction on Windows: unsigned binaries ("Run anyway"), manual
  ConPTY sideload for images, keybinding clashes.

## 9. What users complain about

- Split/tab polish vs. Ghostty/WezTerm: "uncontrollable black lines," bad
  multi-split resize, tabs inheriting zoom state
  ([HN Oct 2025](https://news.ycombinator.com/item?id=45432977)).
- Font rendering: no bitmap fonts ("my main prerequisite... this one fails
  the test" — HN, ibid.); anti-aliasing not disableable
  ([#732](https://github.com/raphamorim/rio/issues/732)); CJK font render
  errors ([#799](https://github.com/raphamorim/rio/issues/799)).
- Windows roughness: startup freezes, opacity, paste, PATH, images (see §6).
- Missing session restore ([#322](https://github.com/raphamorim/rio/issues/322))
  and profiles ([#622](https://github.com/raphamorim/rio/issues/622)) — both
  multi-year requests.
- Name confusion with Plan 9's rio ("a cruel joke on Rob Pike",
  [HN](https://news.ycombinator.com/item?id=49084236)).

## 10. Lessons for noctty

### Does well (adopt-candidates)

1. **ConPTY version escape hatch.** Rio detects/loads a newer `conpty.dll` +
   `OpenConsole.exe` placed beside the exe to un-break image-protocol
   passthrough ([install docs](https://rioterm.com/docs/install/windows)).
   noctty's status/matrix never mentions its ConPTY version strategy;
   shipping or documenting a modern-ConPTY path (and regression-testing
   ConPTY-specific artifacts like the 150–200 ms synchronized-update echo lag
   Rio fixed in 0.5.5) would harden the exact pipeline noctty lives on.
2. **Sixel + iTerm2 image protocols.** noctty ships Kitty graphics only
   (docs/status.md); Rio ships all three. Sixel matters for legacy tooling
   and some TUIs the benchmark user hits in WSL.
3. **Power-aware rendering knobs.** `target-fps`, `disable-unfocused-render`,
   low-power adapter preference ([config docs](https://rioterm.com/docs/config)).
   noctty documents no energy/battery renderer controls; laptop devs
   notice.
4. **Keyboard hints (pattern capture).** Rio's hints let a keyboard-first
   user grab URLs/paths without the mouse ([features](https://rioterm.com/docs/features));
   nothing equivalent appears in noctty's status.md, and it fits
   PRODUCT.md's keyboard-first principle directly.
5. **Prompt-jump scrollback navigation.** OSC 133 `ScrollToPrev/NextPrompt`
   actions ([changelog](https://rioterm.com/changelog)); noctty emits
   OSC 133 marks (shell integration) but status.md never surfaces prompt
   jumping as a Windows-validated workflow — verify and advertise it.
6. **Extra install channels.** Chocolatey and MSYS2 alongside winget/Scoop
   ([install docs](https://rioterm.com/docs/install/windows)) — cheap reach
   into two real Windows-dev populations.
7. **Try-in-browser engine.** The WASM/npm build gives Rio a zero-install
   demo and an ecosystem foothold ([changelog 0.5.20](https://rioterm.com/changelog)).

### Does badly (avoid/exploit)

1. **Windows as the translation-layer platform.** macOS/Linux got native
   backends; Windows still pays the wgpu tax and accumulates open rendering
   bugs (opacity #992, startup #1804). Exploit: noctty's OpenGL+DComp
   pipeline is built *for* Windows — say so, with Rio as the contrast.
2. **Unsigned binaries and "click Run anyway" docs.** noctty's
   Authenticode signing + checksum-verified updater is a direct trust
   differentiator ([install docs](https://rioterm.com/docs/install/windows)
   vs. docs/status.md).
3. **Ship-then-stabilize cadence.** Multiple releases per day, features that
   "actually work now" a version later, search regressions. Exploit with
   PRODUCT.md's "reliability as a feature" — and avoid ever adopting the
   cadence: velocity reads as churn to the benchmark user.
4. **Workflow layer withheld from OSS.** Session restore, quick terminal,
   command bar, and spaces went into closed-source, macOS-only Canario while
   Rio's #322 sits open since 2023. noctty ships session restore and a
   universal palette in the open product today — a durable moat against Rio
   on Windows.
5. **Bus factor 1.** ~97% of recent commits are one person, who has already
   closed one spin-off citing maintenance load (GitHub commit search;
   [rapha.land](https://rapha.land/closing-canario-terminal-source-code/)).
   Any bet a partner/user makes on Rio-on-Windows depends on one individual's
   spare attention to their third platform.
6. **Unverifiable performance marketing.** Self-reported MiB/s with no
   independent benchmarks. Exploit: publish reproducible Windows-specific
   latency/throughput numbers (ConPTY-inclusive) — nobody in this niche does.

### Blind-spot candidates (no PRODUCT.md category)

1. **Zero-install/browser demo surface.** A WASM build of `libghostty-vt`
   (or even a hosted demo) as marketing, docs playground, and bug-repro
   surface — PRODUCT.md has no concept of pre-install experience.
2. **Taste-driven visual delight as a demand category.** Cursor trails, CRT
   shaders, background blur are among Rio's most-shared features; PRODUCT.md
   only has an *anti*-category ("decorative glass, neon..."). A deliberate
   stance on high-demand, opt-in cosmetic polish (with state meaning intact)
   is missing.
3. **Energy/battery as a performance axis.** PRODUCT.md defines success as
   fast/fluid but has no category for power draw, unfocused-window duty
   cycling, or adapter selection on hybrid-GPU laptops.
4. **Embeddable-engine ecosystem as product strategy.** noctty keeps
   `libghostty-vt` buildable but PRODUCT.md treats it as an artifact, not a
   strategy; Rio is actively marketing its engine (C ABI, npm) to grow an
   ecosystem that feeds the terminal.
5. **Wide color gamut / advanced color rendering.** No noctty category
   for color-management fidelity on modern HDR/P3 Windows displays.
