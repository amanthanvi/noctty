# Deep dive: upstream Ghostty (ghostty-org/ghostty)

Executive summary (5 lines):
Upstream Ghostty is a ~60k-star, MIT, non-profit-owned terminal shipping 6-month major releases (1.3.0, 2026-03-09) for macOS/Linux/FreeBSD only; Windows GUI support remains explicitly "still not planned," with the earliest non-committal exploration slot in Nov/Dec 2026. winghostty's core is currently synced to a 1.3.2-dev baseline — it already carries 1.3's headline features (scrollback search, key tables, command-finish notifications) — so the live delta is five months of unmerged main-branch work plus the announced 1.4 wave (Sept 2026: scriptability, true tmux control-mode GUI, graphical preferences). Upstream's strategic center of gravity is shifting to libghostty (C API, Wasm, Go/Rust bindings, Windows CI coverage), which is both the stated path to any official Windows story and a source-layout churn risk for the fork's merges. Two destabilizing upstream events matter: the April 2026 announcement that Ghostty is leaving GitHub (destination still unnamed; the fork's sync remote and updater assumptions touch GitHub), and a recurring quality pattern of big-bang releases followed by fast regression patches. Upstream's durable weaknesses winghostty can exploit: no Windows presence, battery/power-efficiency blind spot, and packaging/toolchain churn that got it dropped from major distro repos.

## 1. Identity & strategy

- What it is: cross-platform (macOS/Linux/FreeBSD), GPU-accelerated terminal with platform-native UI, written in Zig; MIT license; 59,782 stars, 3,289 forks, 249 open issues, pushed daily as of 2026-08-17 (https://github.com/ghostty-org/ghostty).
- Governance: as of 1.3.0, Ghostty is formally a non-profit that "cannot be sold, pivoted, or repurposed for commercial gain," and has signed 5 paid contributor contracts (~300 hours billable) covering community management, graphics, Unicode, GTK, and integrations (https://ghostty.org/docs/install/release-notes/1-3-0). Mitchell Hashimoto remains the dominant author; bus-factor worries are a live community topic (https://news.ycombinator.com/item?id=45354020).
- Strategy: 1.3 is positioned as reaching "best existing terminal emulator" feature completeness; near-term priority is stabilizing and releasing libghostty as a standalone embeddable library, versioned separately from the GUI (https://ghostty.org/docs/install/release-notes/1-3-0, https://mitchellh.com/writing/libghostty-is-coming).
- Platform exodus: announced 2026-04-28 that Ghostty is leaving GitHub over chronic reliability outages; no destination named yet ("talking with multiple providers"); github.com/ghostty-org/ghostty stays as a read-only mirror; issues/PRs/discussions migrate incrementally (https://mitchellh.com/writing/ghostty-leaving-github). As of 2026-08-17 the GitHub repo still receives pushes; migration state beyond the announcement is uncertain.
- Windows stance: 1.3.0 notes say "Support for Microsoft Windows is still not planned" for the app, while libghostty "already supports Windows"; official Windows would come "through libghostty" long-term (https://ghostty.org/docs/install/release-notes/1-3-0). A collaborator in the Windows Q&A discussion (2026-04-15): "the earliest Windows is planned to be looked into is late this year (nov/dec) but dont take that as a commitment"; maintainers reportedly lean toward C# for a hypothetical Windows apprt, acknowledge "a lot of vibecoded forks," and say "some of it could be upstreamed" (https://github.com/ghostty-org/ghostty/discussions/12290).
- Relationship to winghostty: winghostty is a hard fork; local `build.zig.zon` shows `version = "1.3.2-dev"`, i.e. the shared core is synced through the 1.3.1+ line (verified against this repo's [`build.zig.zon`](../../../../build.zig.zon)).

## 2. Performance & fluidity

- Rendering: per-platform GPU backends (Metal on macOS, OpenGL on GTK) with a consolidated shared renderer core since 1.2 (https://ghostty.org/docs/install/release-notes/1-2-0). No official published latency/throughput benchmark suite; claims are release-note-level.
- 1.3.0 performance work (all in the fork's 1.3.2-dev core already, but the methodology is the lesson): the team replayed ~4GB of public asciinema recordings as an I/O corpus, cutting replay time "from minutes to tens of seconds," and reworked the renderer to cut terminal lock time 2x–5x in most scenarios (https://ghostty.org/docs/install/release-notes/1-3-0).
- Post-1.3 main-branch work (not in the fork): continued perf iteration including Wasm terminal memory reduced ~75% via custom memory pooling, streaming C-API formatters, and UTF-8/VT rendering fixes (commit log, https://github.com/ghostty-org/ghostty/commits/main, observed 2026-08-17).
- Known efficiency weakness: performance-first design with no GPU-off mode and no power-state adaptation; sustained community reports of high battery drain (120fps custom-shader rendering, blur, cursor timers active on battery) — https://github.com/ghostty-org/ghostty/discussions/3883, https://github.com/ghostty-org/ghostty/discussions/11941, https://github.com/ghostty-org/ghostty/issues/11928.

## 3. Native Windows integration

- None in the shipping product. No Windows binaries, no ConPTY code path in the GUI, no installer/winget/MSIX presence. The features page still lists Windows as not supported (mirrored by winghostty's capability matrix row, docs/windows-capability-matrix.md).
- The only Windows surface is libghostty CI: Hashimoto states libghostty supports "32 and 64-bit, Windows, Android," with CI coverage expanding per C API added (https://x.com/mitchellh/status/2032955206540079377). This is compile/unit coverage of the core, not a pty, renderer, or window system story.
- Implication: everything in rubric section 3 (Snap Layouts, jump lists, taskbar, toasts, default-terminal, WSL, elevation, ARM64 apps) is winghostty-only territory today. The credible threat window opens if upstream starts a C#-based Windows apprt after Nov/Dec 2026 (https://github.com/ghostty-org/ghostty/discussions/12290) — uncertain and non-committal.

## 4. Terminal capability

The fork shares this core, so parity is high by construction; the delta is main-branch drift.

- In 1.3.0 (present in fork core, locally verified for search/key-tables/clipboard-map/notify options): scrollback search on a dedicated search thread; OSC 133 click-to-move (`cl=line`, Kitty `click-events`; works with Fish 4.1+/Nushell 0.111+); more complete OSC 133; ConEmu OSC 9 subcommands 1–12; synchronous color-scheme reports; CSI SU preserving scrolled-off lines; parse support for Kitty text sizing (OSC 66), iTerm2 OSC 1337, Kitty clipboard (OSC 5522); Unicode 17 with full grapheme-cluster conformance and corrected Brahmic-script rendering; rich clipboard copy (plain/HTML/VT) (https://ghostty.org/docs/install/release-notes/1-3-0).
- tmux control mode: 1.3 shipped significant parsing (present in the fork at src/terminal/tmux/, parse-only); the 1.4 roadmap promises "true Tmux control mode" — GUI-integrated, iTerm2-style native tmux windows (https://ghostty.org/docs/install/release-notes/1-3-0). That GUI hookup is upstream work the fork will need to reimplement against the Win32 apprt.
- Security: CVE-2026-26982 (control characters in pasted/dragged text could execute commands) fixed in 1.3.0 with xterm-style replacement of unsafe control chars (https://ghostty.org/docs/install/release-notes/1-3-0). The fork's 1.3.2-dev baseline should include it; not independently re-verified in the fork's paste path — worth a one-time audit of the Win32 clipboard/drag-drop code, which is fork-specific and outside upstream's fix surface.
- Post-1.3 main: kitty key-release handling, UTF-8 preservation fixes, VT formatting fixes (https://github.com/ghostty-org/ghostty/commits/main).

## 5. Workflow features

- Upstream (1.3): tabs/splits with drag-to-reorder splits (macOS, undo/redo integrated), editable tab titles, split-preserve-zoom, per-tab/split working-directory inheritance controls, command palette with custom entries (macOS), quick terminal, key tables/chained keybinds for tmux-like modal workflows, notify-on-command-finish trio of options (https://ghostty.org/docs/install/release-notes/1-3-0).
- Session restore: macOS restores window state; upstream has no cross-platform session-restore feature comparable to winghostty's `window-save-state` JSON restore of windows/tabs/splits/profiles/cwds (docs/status.md).
- No broadcast input, no iTerm-style instant replay/annotations/timestamps — requested on HN (https://news.ycombinator.com/item?id=47311129).
- 1.4 roadmap adds scriptability and graphical preferences (https://ghostty.org/docs/install/release-notes/1-3-0) — winghostty already ships a native settings window with staged source-preserving saves (docs/status.md), i.e. the fork is ahead of upstream here today, but upstream's version will define user expectations for "Ghostty settings UI."

## 6. Reliability & quality signals

- Quality engineering upstream invests in that the fork has no visible equivalent for its own code: extensive AFL++ fuzzing of the escape-sequence parser and VT stream (found ~10 crashes/memory-safety issues), a purpose-built "Tripwire" tool to test Zig errdefer cleanup paths, Valgrind-tested leak-free GTK rewrite (1.2), and corpus-replay performance regression testing (https://ghostty.org/docs/install/release-notes/1-3-0, https://ghostty.org/docs/install/release-notes/1-2-0).
- Fixed a major memory leak affecting Claude Code users that had existed since 1.0 (https://ghostty.org/docs/install/release-notes/1-3-0) — evidence that even heavily-used cores hide long-lived leaks.
- Regression pattern: 1.3.0 (Mar 9) needed 1.3.1 (Mar 13, 100+ commits, 15 contributors) within four days, dominated by macOS regressions: phantom mouse events, window sizing, tab-title focus, keybind overrides (https://ghostty.org/docs/install/release-notes/1-3-1). Six-month release trains concentrate risk.
- Issue tracker: 249 open issues against ~60k stars is lean; dominant negative themes are battery/power (see §2) and platform/packaging churn (see §8).

## 7. Configuration & extensibility

- Same config grammar the fork inherits. 1.3 additions (in fork core): `scrollbar`, `key-remap`, `clipboard-codepoint-map`, `selection-word-chars`, `mouse-reporting`, `scroll-to-bottom=output`, `split-preserve-zoom`, notify-on-command-finish trio; 1.3.1 added `progress-style`, `set_surface_title`/`set_tab_title` actions (https://ghostty.org/docs/install/release-notes/1-3-0, https://ghostty.org/docs/install/release-notes/1-3-1). Whether every new option is wired to Win32 behavior (e.g., whether `scrollbar` renders a native Win32 scrollbar like upstream's macOS/GTK overlay scrollbars) is a fork-side audit item — config presence was verified locally, apprt wiring was not.
- Scripting: AppleScript automation shipped as a 1.3 preview (macOS); 1.4 promises general "scriptability" (https://ghostty.org/docs/install/release-notes/1-3-0). winghostty's `+list-windows` / allowlisted `+perform-action` IPC (docs/windows-capability-matrix.md) is comparable in spirit but will diverge from whatever scripting contract upstream standardizes.
- Extensibility as a platform: libghostty with a WIP C API, "dozens of projects both free and commercial" already embedding it; Go bindings (https://github.com/mitchellh/go-libghostty), a Rust crate (https://lib.rs/crates/libghostty-vt), Wasm target; Ghostling demo — a functional standalone terminal in ~600 lines of C on libghostty (https://x.com/mitchellh/status/2035114092151902357). No tagged libghostty release yet as of mid-2026 (uncertain; no release announcement found — https://mitchellh.com/writing/libghostty-is-coming set a ~6-month tagging goal from Sept 2025 that has slipped).

## 8. Packaging & adoption

- Channels: macOS (signed/notarized DMG, Homebrew), Linux (distro packages, Snap, Flatpak in progress upstream). Momentum: 1.3.0 had 180 contributors / 2,858 commits over 6 months; 1.2.0 had 149 / 2,676 (release notes). ~59.8k stars.
- Docs site (ghostty.org) is high quality: full config reference, VT reference with per-sequence docs, exhaustive release notes the maintainers say take "16+ hours to write" (https://ghostty.org/docs/install/release-notes/1-3-0).
- Packaging fragility: HN reports that openSUSE, Debian, and Ubuntu dropped Ghostty from repos because fast-moving Zig/dependency requirements weren't maintainable, and the GitHub exodus forces distro packagers to retool automation (reported in HN discussion of the move; https://news.ycombinator.com/item?id=47311129 thread context and https://www.qwe.edu.pl/tutorial/ghostty-leaving-github/ — secondary sources, moderate confidence).
- Cadence: strict ~6-month majors (1.2.0 Sept 2025 → 1.3.0 Mar 2026 → 1.4.0 planned Sept 2026) with fast patch follow-ups (https://ghostty.org/docs/install/release-notes).

## 9. What users complain about

- Battery/power drain, no way to reduce GPU work on battery: "Ghostty consumes a LOT of battery... GPU or nothing" (https://github.com/ghostty-org/ghostty/discussions/3883, https://github.com/ghostty-org/ghostty/discussions/11941, https://github.com/ghostty-org/ghostty/issues/11928).
- No Windows support — the single largest platform gap; the official Windows discussion threads (#2563, #12290) stay active with no commitment (https://github.com/ghostty-org/ghostty/discussions/2563, https://github.com/ghostty-org/ghostty/discussions/12290).
- Missing power-user features vs iTerm2: native tmux integration, instant replay, scrollback timestamps/annotations, global search (HN 1.3.0 thread, https://news.ycombinator.com/item?id=47311129).
- Distro packaging drops due to Zig toolchain churn (see §8).
- Bus factor / founder dependency: "I only wish after 1.3 he could hand over Ghostty to others" (https://news.ycombinator.com/item?id=45354020).
- Regression-heavy majors (1.3.0 → 1.3.1 in 4 days; https://ghostty.org/docs/install/release-notes/1-3-1).

## 10. Lessons for winghostty

Hard-fork vs. soft-fork framing: wintty's daily-rebase model buys automatic parity but caps divergence at what stays rebasable; winghostty's hard fork bought an entire native Win32 apprt (native settings UI, universal palette, session restore, UIA, tab drag — docs/status.md) that could never survive as a rebase patch-set. The cost is now measurable: the fork sits at a 1.3.2-dev core while upstream main has ~5 months of daily commits heading to 1.4, and two upstream shocks — the GitHub exodus and the libghostty source-tree extraction — will raise future merge cost. The fork's Windows moat is real precisely because upstream keeps deferring Windows; the merge treadmill is the price of that moat.

### Does well (adopt-candidates)

1. Corpus-and-fuzzing QA infrastructure: AFL++ on the VT stream, Tripwire for errdefer paths, asciinema-corpus replay as a perf regression suite (1.3.0 notes). winghostty inherits the fuzzed core but has zero equivalent coverage for its fork-only surfaces (Win32 clipboard/drag-drop paste paths, ConPTY I/O, session-state JSON, IPC) — docs/status.md lists no fuzz/corpus story.
2. Scheduled upstream-sync cadence ahead of 1.4 (Sept 2026): merge main incrementally now (kitty key-release fixes, UTF-8/VT fixes, renderer work) rather than absorbing scriptability + tmux-control-GUI + graphical-preferences as one big-bang conflict with the fork's own settings window and palette.
3. tmux control mode GUI integration: fork has the 1.3 parser (src/terminal/tmux/); upstream 1.4 will hook it into native windows. For the benchmark WSL user, native tmux panes-as-Win32-splits would be a marquee feature — design the Win32 hookup against upstream's integration to keep the core shareable.
4. Automation contract: upstream is converging on first-class scriptability (AppleScript preview now, general scriptability in 1.4). Align winghostty's `+perform-action` IPC with upstream's eventual scripting surface, exposed PowerShell-natively.
5. Release-notes and docs discipline as adoption fuel: exhaustive per-release notes and a complete config/VT reference are a large part of Ghostty's credibility; the fork's docs/status.md is honest but thin by comparison for new-user onboarding.
6. Per-feature wiring audit of 1.3 config surface: options verified present in the fork's core (`scrollbar`, `key-remap`, notify-on-command-finish, clipboard-codepoint-map) need confirmed Win32 behavior parity — upstream ships native overlay scrollbars on both its platforms; a native Win32 overlay scrollbar equivalent is not documented in docs/status.md.

### Does badly (avoid/exploit)

1. No Windows product, non-committal roadmap (earliest exploration Nov/Dec 2026, maintainers musing about C#): winghostty has a 12–24 month execution window to become the definitive "Ghostty on Windows" before any official effort exists — and upstream's stated openness to upstreaming community Windows work (#12290) is a standing strategic option.
2. Battery/power blind spot: GPU-or-nothing rendering, no power-state adaptation, recurring drain complaints. Exploit: make winghostty demonstrably laptop-polite on Windows (occlusion-aware repaint, reduced cadence on battery/power-saver, measurable idle wattage) — a differentiator upstream structurally deprioritizes.
3. Toolchain/packaging churn that got Ghostty dropped by openSUSE/Debian/Ubuntu: keep winghostty's winget/Scoop channels boring and continuously installable; pin and document Zig toolchain requirements per release.
4. Big-bang 6-month releases followed by 4-day regression patches: ship smaller, more frequent winghostty releases so the Windows-specific surface never accumulates a 2,800-commit risk wave.
5. GitHub exodus fallout: upstream's move (destination still unannounced) threatens the fork's merge remote, link rot in shared docs, and packager automation. Prepare: track the mirror's freshness, be ready to re-point sync tooling, and note that winghostty's own updater hardcodes api.github.com (docs/status.md) — a dependency upstream itself just judged unreliable.

### Blind-spot candidates (no category in PRODUCT.md)

1. Embeddable-library strategy: upstream treats the terminal core as a product (libghostty: C API, Wasm, Go/Rust bindings, Windows CI, commercial adopters). PRODUCT.md has no position on winghostty as a libghostty consumer/contributor — yet the fork's long-term merge cost and even upstream's future Windows story both hinge on libghostty's API churn.
2. Sustainability/governance as product risk: upstream is a non-profit paying contractors; winghostty is one maintainer. PRODUCT.md declares governance out of scope, but bus factor directly threatens the "reliability as a feature" promise.
3. Power efficiency as a first-class success metric: neither PRODUCT.md's purpose nor its principles mention battery/energy; upstream's complaint stream shows terminal users do.
4. Localization: upstream ships translations (six new languages in 1.3.0); PRODUCT.md has no i18n category despite targeting "Windows developers" globally (IME support exists, UI strings are English-only).
5. Code-hosting/supply-chain independence: upstream is actively de-platforming from GitHub for reliability; winghostty's distribution, update checks, and community surfaces are all GitHub-coupled with no contingency category.
