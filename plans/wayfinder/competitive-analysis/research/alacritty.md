# Alacritty — deep dive

Executive summary (five lines):
Alacritty is the minimal-fast benchmark: a two-maintainer Rust/OpenGL terminal (65k+ stars, dual MIT/Apache-2.0) that deliberately refuses tabs, splits, scrollback UI, ligatures, graphics protocols, and GUI config, betting everything on throughput, latency, and a lean core. The discipline pays: a 2.3 MB MSI, near-top latency/FPS in every 2025–26 community benchmark, ~330 open issues, and a release train (v0.17.0, Apr 2026) that almost never regresses. On Windows it is a tier-2 citizen: ConPTY works, but binaries are unsigned, there is no ARM64 build, no colored emoji since 2019, no default-terminal registration, and its flagship daemon/IPC single-instance mode is `cfg(unix)`-gated. The "use tmux for tabs" answer collapses on Windows, where tmux doesn't run natively — so the benchmark user this rubric judges against is structurally unserved. Lesson for winghostty: adopt the perf-as-artifact culture (vtebench-style CI), hints/vi-mode keyboard text capture, and SignPath-style signing; exploit the workflow vacuum Alacritty refuses to fill.

## 1. Identity & strategy

- What: "A modern terminal emulator that comes with sensible defaults, but allows for extensive configuration," Rust + OpenGL, cross-platform (BSD/Linux/macOS/Windows). Self-described as "beta level of readiness" yet "used by many as a daily driver" ([README](https://github.com/alacritty/alacritty)).
- Strategy: "integrating with other applications, rather than reimplementing their functionality." Explicit non-features in the README: "Tabs or splits (which are best left to a window manager or terminal multiplexer)" and a GUI config editor ([README](https://github.com/alacritty/alacritty)).
- Target user: tiling-WM / tmux power users on Unix; performance purists. Windows is supported but clearly not the design center (see §3).
- Governance/bus factor: two maintainers, Christian Dürr and Kirill Chibisov ([man page authors](https://man.archlinux.org/man/alacritty.1), [org people](https://github.com/orgs/alacritty/people)); founder Joe Wilm no longer active. Bus factor ≈ 2, but the deliberately small surface makes that survivable.
- License: dual Apache-2.0 / MIT. Momentum: 65.4k stars, 3.6k forks ([README](https://github.com/alacritty/alacritty)); roughly two minor releases per year (0.16.0 Oct 2025 → 0.17.0 Apr 2026, [releases](https://github.com/alacritty/alacritty/releases)).

## 2. Performance & fluidity

- Rendering: OpenGL 3.3 instanced glyph rendering with a GLES 2.0 fallback path added in 0.11 — minimum requirement is OpenGL ES 2.0 ([README](https://github.com/alacritty/alacritty), [rendering pipeline overview](https://deepwiki.com/alacritty/alacritty/3.4-rendering-pipeline)). Note the contrast: winghostty requires GL 4.3+.
- Damage model: Alacritty *reports* damage to Wayland compositors ([PR #5773](https://github.com/alacritty/alacritty/pull/5773), 0.11.0) but still redraws the full grid every frame — partial rendering is a still-open issue ([#5843](https://github.com/alacritty/alacritty/issues/5843)). Instructive: brute-force full redraw + instancing is fast enough to top benchmarks; damage complexity is not where its speed comes from.
- Throughput: the project maintains its own benchmark harness, [vtebench](https://github.com/alacritty/vtebench), and frames its performance claims through it — performance is a measured artifact, not marketing prose.
- Latency/FPS third-party data (rough, methodology varies): 2025–26 community benchmarks put Alacritty at ~3 ms key-to-screen / ~404 FPS, statistically neck-and-neck with Ghostty (~2 ms / 407 FPS) and kitty ([moktavizen/terminal-benchmark](https://github.com/moktavizen/terminal-benchmark), [2026 roundup](https://www.pistack.xyz/posts/2026-08-10-ghostty-vs-alacritty-vs-wezterm-terminal-emulator-guide/)). A long-time Alacritty user evaluating Ghostty in 2025 still found Alacritty "slightly more responsive" ([lugh.ch](https://lugh.ch/ghostty-for-alacritty-users.html)). Treat exact numbers as noisy; the stable finding is "top tier, no longer uniquely fastest."
- Startup: famously quick cold start; 0.14 added a `--daemon` mode + `alacritty msg create-window` so subsequent windows spawn from a warm process ([changelog](https://raw.githubusercontent.com/alacritty/alacritty/master/CHANGELOG.md), [single-instance writeup](https://dzx.fr/blog/alacritty-single-instance/)) — but this is unix-only (§3).
- Recent perf/robustness fixes: 0.16.1 fixed "crashes on GPUs with partial robustness support"; 0.17.0 fixed OpenGL context-reset crashes ([releases](https://github.com/alacritty/alacritty/releases)) — evidence that GPU-diversity hardening is a real, ongoing cost even for a minimal renderer.

## 3. Native Windows integration

- PTY: ConPTY, required (Windows 10 1809+); the legacy winpty backend was removed years ago (ConPTY default since 0.4.1, winpty deprecated by 0.6.0) ([changelog](https://raw.githubusercontent.com/alacritty/alacritty/master/CHANGELOG.md)). `main.rs` carries explicit comments about ConPTY drop-order requirements to avoid shutdown deadlocks ([alacritty/src/main.rs](https://github.com/alacritty/alacritty/blob/master/alacritty/src/main.rs)) — ConPTY jank is handled but not abstracted away.
- Chrome/shell integration: essentially none beyond a working window. No Snap Layouts work, no jump lists, no taskbar progress, no notifications. "Open Alacritty Here" Explorer context menu shipped in 0.12, extended to folders in 0.18-dev ([changelog](https://raw.githubusercontent.com/alacritty/alacritty/master/CHANGELOG.md)).
- Default-terminal registration: not implemented; open request since Apr 2022 ([#6036](https://github.com/alacritty/alacritty/issues/6036)).
- ARM64: no Windows ARM64 release asset — v0.17.0 ships only an x64 MSI (2.29 MB) and portable exe (5.73 MB) ([release assets](https://github.com/alacritty/alacritty/releases/tag/v0.17.0)).
- Code signing: Windows binaries are unsigned; "Publisher: Unknown"/SmartScreen complaints date to 2021 ([#4731](https://github.com/alacritty/alacritty/issues/4731)); an Oct 2025 issue proposes free signing via SignPath Foundation ([#8725](https://github.com/alacritty/alacritty/issues/8725)). Unresolved as of this dive.
- Long-lived Windows defects: colored emoji unsupported since 2019 ([#3082](https://github.com/alacritty/alacritty/issues/3082)); moving a window between monitors with different scale factors broken ([#8108](https://github.com/alacritty/alacritty/issues/8108), 2024); fullscreen alt-tab issue ([#8478](https://github.com/alacritty/alacritty/issues/8478), 2025). Windows font fallback was historically missing (fixed via [#3215](https://github.com/alacritty/alacritty/issues/3215)/[#3127](https://github.com/alacritty/alacritty/pull/3127)); DirectWrite quality complaints ("denty," missing AA vs Windows Terminal) recur ([#2645](https://github.com/jwilm/alacritty/issues/2645)).
- WSL: works by setting the shell to `wsl.exe`; no distro discovery, profiles, or per-distro cwd handling. A 2020 proposal to use a genuine Linux PTY via WSL sits open ([#3707](https://github.com/alacritty/alacritty/issues/3707)).
- Elevation/UAC: no special handling found (no packaged elevation story). Uncertain — no explicit docs either way.
- The structural problem: Alacritty's official answer to tabs/splits is "window manager or multiplexer," but native Windows has no tiling-WM culture and tmux does not run outside WSL/MSYS ([#1687](https://github.com/alacritty/alacritty/issues/1687): "open terminal failed: not a terminal," open since 2018). The philosophy's load-bearing assumption fails on exactly this rubric's benchmark user.

## 4. Terminal capability

- VT core: mature `vte`-based parser; solid xterm/DEC coverage; Unicode 17 in 0.16.0; kitty keyboard protocol since 0.13.0 ([changelog](https://raw.githubusercontent.com/alacritty/alacritty/master/CHANGELOG.md)).
- Graphics protocols: none — no sixel, no kitty graphics, no iTerm2 images. Community forks add sixel ([HN discussion of sixel fork](https://news.ycombinator.com/item?id=34366931)); mainline declines. winghostty ships kitty graphics; this is a hard capability edge over Alacritty.
- Ligatures: refused for years ([#50 lineage; #3700](https://github.com/alacritty/alacritty/issues/3700), [#5245](https://github.com/alacritty/alacritty/issues/5245)); a fork (`alacritty-ligatures`) exists. A recurring top complaint.
- Hyperlinks: OSC 8 supported (0.11 era) and integrated with the hints system; URLs clickable with modifier ([features.md](https://github.com/alacritty/alacritty/blob/master/docs/features.md)).
- Clipboard: OSC 52 supported; single-clipboard semantics fine on Windows. Mouse modes standard.
- Shell integration: none. OSC 133 prompt-marks request open since Feb 2022 with no implementation ([#5850](https://github.com/alacritty/alacritty/issues/5850)). No prompt jumping, no command duration, no cwd tracking beyond what the shell does itself.
- Search & scrollback: regex search over scrollback (Ctrl+Shift+F/B), vi mode for keyboard navigation/selection of the viewport and scrollback, and "hints" — configurable regexes over visible text that feed matches to an external command or built-in action ([features.md](https://github.com/alacritty/alacritty/blob/master/docs/features.md)). No scrollbar, ever ([RFC #775](https://github.com/alacritty/alacritty/issues/775), [HN](https://news.ycombinator.com/item?id=40439735)).

## 5. Workflow features

- Tabs/splits: refused by design ([README](https://github.com/alacritty/alacritty); [#6340 "Why are multiple tabs not supported?"](https://github.com/alacritty/alacritty/issues/6340)). Multi-window only: `CreateNewWindow` binding, or `alacritty msg create-window` against a running instance ([features.md](https://github.com/alacritty/alacritty/blob/master/docs/features.md)).
- The daemon/IPC path (`--daemon`, `alacritty msg`, IPC config get/set added 0.16) is `#[cfg(unix)]` — the msg subcommand, socket spawn, and cleanup are all unix-gated in [main.rs](https://github.com/alacritty/alacritty/blob/master/alacritty/src/main.rs). Windows users get none of the single-instance/scripting story.
- Session restore: none of any kind. No profiles (one config file; variants via `--config-file`/`-o` overrides). No command palette, no quick/dropdown terminal, no broadcast input.
- Keybindings: fully rebindable, chords no; vi mode motions expanded in 0.16 (`*`, `#`, `{`, `}`); mouse-wheel bindings in 0.17 ([changelog](https://raw.githubusercontent.com/alacritty/alacritty/master/CHANGELOG.md)).
- Net: for this rubric's benchmark user (tabs, splits, session layout surviving restarts), Alacritty offers approximately nothing by policy.

## 6. Reliability & quality signals

- Open issues: ~329 total ([issue tracker](https://github.com/alacritty/alacritty/issues)) — remarkably low for 65k stars; aggressive triage and a narrow surface keep the tracker clean.
- Release stability: patch releases are small and targeted (0.16.1 = one GPU crash class); regressions are rare in third-party reporting. The "beta" label persists in the README yet belies daily-driver stability.
- Dominant issue themes: fonts (fallback, emoji, rendering quality), platform windowing quirks (DPI, fullscreen), and re-litigations of refused features (tabs, scrollbar, ligatures).
- Community reputation cost: maintainer terseness/hostility toward bug reports is a recurring meme and an explicitly cited reason users moved to Ghostty ("Ghostty's community is much nicer compared to Alacritty," [HN](https://news.ycombinator.com/item?id=42521010)). Uncertain how representative; but the perception is documented and repeated.
- CI/test: vtebench exists for perf; core has unit tests and ref-tests (grid snapshots) — standard for the project, not independently benchmarked here (uncertainty flagged).

## 7. Configuration & extensibility

- Config: single TOML file (`%APPDATA%\alacritty\alacritty.toml` on Windows); migrated from YAML in 0.13.0 with a `migrate` tool in 0.14 ([changelog](https://raw.githubusercontent.com/alacritty/alacritty/master/CHANGELOG.md), [README](https://github.com/alacritty/alacritty)). The migration generated notable user grumbling but was tool-assisted — a competent breaking-change execution.
- Live reload: yes, file-watch based. TOML 1.1 syntax accepted since 0.17.0.
- GUI: none, by policy. Theming: via config imports; community `alacritty-theme` repo, no in-app theme browser.
- Extensibility: no plugins, no scripting API. The hints system (regex → external command) is the sole escape hatch, and it's a good one. IPC config get/set (0.16) enables runtime re-theming from scripts — unix-only.

## 8. Packaging & adoption

- Windows channels: WinGet (`Alacritty.Alacritty`), Scoop (extras), Chocolatey, plus MSI and portable exe from GitHub Releases, and `cargo install` ([winget.run](https://winget.run/pkg/Alacritty/Alacritty), [release assets](https://github.com/alacritty/alacritty/releases/tag/v0.17.0)).
- Update mechanism: none — no update checks at all; users rely on package managers. Binaries unsigned (§3).
- Footprint: 2.29 MB MSI / 5.73 MB portable exe — an order of magnitude leaner than most GPU terminals; the minimalism is legible in the artifact itself.
- Docs: man pages (alacritty.1/.5, alacritty-msg.1, bindings.5, escapes.7) + [alacritty.org](https://alacritty.org) reference pages + repo markdown. Accurate but terse; Windows-specific docs are thin.
- Momentum: 65.4k stars / 3.6k forks; ~2 releases/year; two maintainers. Stable-mature rather than growing; 2025–26 mindshare visibly bleeding to Ghostty in comparison posts ([lugh.ch](https://lugh.ch/ghostty-for-alacritty-users.html), [HN](https://news.ycombinator.com/item?id=45803214)).

## 9. What users complain about

- No tabs/splits — the perennial #1: "Alacritty I like but the lack of tabs is not acceptable" ([HN](https://news.ycombinator.com/item?id=47207922)); [#6340](https://github.com/alacritty/alacritty/issues/6340).
- No scrollbar: "There still are no scrollbars in Alacritty" ([HN](https://news.ycombinator.com/item?id=40439735), [RFC #775](https://github.com/alacritty/alacritty/issues/775)).
- No ligatures ([#3700](https://github.com/alacritty/alacritty/issues/3700), [HN](https://news.ycombinator.com/item?id=24646267)).
- Font rendering quality on macOS and Windows ("actually pretty bad at font rendering quality," [HN](https://news.ycombinator.com/item?id=23372157); Windows "denty" rendering [#2645](https://github.com/jwilm/alacritty/issues/2645)).
- Windows second-class: unsigned installers ([#4731](https://github.com/alacritty/alacritty/issues/4731)), no colored emoji ([#3082](https://github.com/alacritty/alacritty/issues/3082)), mixed-DPI window moves ([#8108](https://github.com/alacritty/alacritty/issues/8108)).
- Maintainer tone / dismissive issue handling driving churn to Ghostty ([HN](https://news.ycombinator.com/item?id=42521010)).
- "Not uniquely fastest anymore": benchmark parity with Ghostty/kitty removes the one differentiator that justified the austerity for some users ([moktavizen benchmark](https://github.com/moktavizen/terminal-benchmark)).

## 10. Lessons for winghostty

### Does well (adopt-candidates)

1. **Performance as a published, reproducible artifact.** Alacritty ships [vtebench](https://github.com/alacritty/vtebench) and frames all speed claims through it. winghostty's PRODUCT.md promises "fastest, most fluid" with no benchmark harness or CI perf gate anywhere in docs/status.md. Adopt vtebench (it's terminal-agnostic) + a latency methodology, publish numbers vs Windows Terminal/Alacritty-on-Windows, and gate regressions in CI.
2. **Hints: regex-driven keyboard text capture.** Configurable regexes over visible text → open/copy/paste/pipe-to-command, keyboard-selectable without a mouse ([features.md](https://github.com/alacritty/alacritty/blob/master/docs/features.md)). winghostty has OSC 8 hyperlinks but no quick-select/hints layer; for a keyboard-first audience this is a high-value, well-scoped feature.
3. **Vi mode + scrollback search.** Keyboard navigation/selection of scrollback plus regex search shipped and polished. winghostty's status.md lists no search UI or keyboard scrollback navigation at all despite PRODUCT.md naming search as a success criterion — this is the benchmark's clearest capability gap.
4. **Footprint and GPU floor.** 2.3 MB MSI; renderer falls back to GLES 2.0, and 0.16.1/0.17.0 hardened against partially-robust GPUs ([releases](https://github.com/alacritty/alacritty/releases)). winghostty requires OpenGL 4.3+, which excludes old iGPUs/VMs/RDP-ish environments; Alacritty shows the floor can be far lower. At minimum, fail gracefully and document the floor.
5. **SignPath Foundation signing.** Alacritty's community identified [free OSS code signing via SignPath](https://github.com/alacritty/alacritty/issues/8725) as the answer to SmartScreen. winghostty already signs but "SmartScreen can still warn for a low-reputation publisher" (status.md) — SignPath or EV-style reputation building is directly applicable.
6. **Full-redraw simplicity.** Alacritty tops benchmarks while redrawing the whole grid with instancing ([#5843](https://github.com/alacritty/alacritty/issues/5843) partial rendering still open). Lesson: don't buy damage-tracking complexity in the terminal renderer until profiling demands it.

### Does badly (avoid / exploit)

1. **The "use a multiplexer" answer is broken on Windows.** tmux doesn't run under native Windows ([#1687](https://github.com/alacritty/alacritty/issues/1687), open since 2018), tiling WMs are fringe, so Alacritty's Windows users get neither tabs nor a sanctioned substitute. winghostty's integrated tabs/splits/session-restore is the direct exploit; say so explicitly in positioning.
2. **No session restore, no profiles, no palette** — by policy. Everything PRODUCT.md's benchmark user needs daily is a permanent non-goal there. Differentiation is free; winghostty just has to keep those features fast enough that the austerity argument loses.
3. **Unix-only IPC/daemon.** Alacritty's single-instance fast-spawn and scripting surface literally `#[cfg(unix)]`-compiles away on Windows ([main.rs](https://github.com/alacritty/alacritty/blob/master/alacritty/src/main.rs)). winghostty's `+list-windows`/`+perform-action` over single-instance IPC is already ahead — keep investing; it's a real moat vs every cross-platform terminal that treats Windows IPC as an afterthought.
4. **Windows tier-2 debt compounds.** Unsigned binaries (2021→2025 unresolved), no ARM64, colored emoji missing 6+ years, mixed-DPI moves broken, default-terminal registration never done. Each is small; together they read as contempt. winghostty already covers signing/ARM64/DPI — close the loop with default-terminal registration (Alacritty's [#6036](https://github.com/alacritty/alacritty/issues/6036) shows demand) — noting it's also absent from winghostty's matrix today.
5. **No shell integration / OSC 133** ([#5850](https://github.com/alacritty/alacritty/issues/5850) open 4 years). winghostty ships OSC 133 + PowerShell integration; surface user-visible payoffs (jump-to-prompt, select-command-output) so the advantage is felt, not just implemented.
6. **Community tone as churn engine.** Documented perception of hostile triage pushed users to Ghostty ([HN](https://news.ycombinator.com/item?id=42521010)). Cheap avoidance: keep Discussions welcoming, template issues without gatekeeping.
7. **Refusals age badly once speed parity arrives.** With Ghostty/kitty matching Alacritty's latency ([benchmarks](https://github.com/moktavizen/terminal-benchmark)), "no features because fast" stops converting. Don't let winghostty's minimal chrome rhetoric become the identity; the identity is fast *and* workflow-complete.

### Blind-spot candidates (no category in PRODUCT.md)

1. **A benchmark/perf-budget category.** PRODUCT.md asserts speed but defines no measurable target, harness, or regression gate. Alacritty's vtebench culture shows what "performance as a feature" looks like operationally.
2. **Minimum-GPU floor and degraded-mode policy.** Nothing in PRODUCT.md/status.md addresses what happens on GL < 4.3, remote desktop sessions, VMs, or partially-robust drivers — a class Alacritty actively engineers for (GLES2 path, robustness crash fixes).
3. **A hints/quick-select interaction category** — keyboard capture of arbitrary on-screen text (URLs, paths, hashes) as a first-class surface, distinct from clickable hyperlinks.
4. **Binary footprint / install weight as a stated value.** Alacritty's 2.3 MB MSI is itself marketing; winghostty has no size or cold-start budget anywhere.
5. **An explicit public non-goals contract.** Alacritty's README refusal list is harsh but honest, and it successfully manages expectations for a two-person team. winghostty's PRODUCT.md has anti-references but no user-facing "what we will never do" statement to deflect scope pressure.
6. **Default-terminal registration** (Windows "default terminal application" handoff) — absent from PRODUCT.md, status.md, and the capability matrix, yet demanded by users of every Windows terminal ([alacritty#6036](https://github.com/alacritty/alacritty/issues/6036)).
