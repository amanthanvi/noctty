# WezTerm — Deep Dive

Executive summary (five lines):
WezTerm is the strongest cross-platform power-user terminal available on Windows: a Rust, GPU-accelerated emulator whose differentiators are a full Lua scripting surface (~250+ options, events, git-distributed plugins) and built-in multiplexing (local/SSH/TLS/Unix/WSL domains with detach-reattach) plus a native SSH client — categories noctty does not have at all. Its Windows story is a port, not a home: minute-scale startup pathologies, nightly-only fixes, no default-terminal registration, no native ARM64, and ConPTY-era baggage. The project is alive (near-daily commits as of Aug 2026, contributor "bew" now dominating the log) but has shipped no stable release since 2024-02-03, so winget/Scoop users sit on a 2.5-year-old build and periodically ask if the project is dead. Memory is a chronic weakness (all-RAM scrollback, mux-layer leaks, 1.4–5 GiB RSS reports), and its Kitty graphics/keyboard support is opt-in and non-conformant. For noctty the payload is: adopt scripting/automation, session-process persistence via a mux concept, quick-select/copy-mode, and font-debug tooling; exploit the stale-release channel, Windows startup latency, and memory story with disciplined signed releases and native-Windows polish.

## 1. Identity & strategy

- "A GPU-accelerated cross-platform terminal emulator and multiplexer … implemented in Rust," by Wez Furlong; explicitly a "spare time project" ([repo](https://github.com/wezterm/wezterm)). MIT-licensed ([LICENSE.md](https://github.com/wezterm/wezterm/blob/main/LICENSE.md)).
- Target user: power users who want terminal + tmux + ssh client in one binary, configured in one Lua file that travels across Linux/macOS/Windows/FreeBSD ([features](https://wezterm.org/features.html)). The pitch is uniformity — the exact opposite of noctty's native-first bet.
- Not a fork of anything; its own VT implementation (`termwiz`) and mux stack. Repo moved from `wez/wezterm` to a `wezterm` GitHub org (old URLs redirect), suggesting an intent to broaden stewardship; no formal governance doc found (uncertain).
- Bus factor: historically one person (wez). As of Aug 2026 the commit log is dominated by contributor **bew**, with wez still merging ([commits](https://github.com/wezterm/wezterm/commits/main)). Whether bew has formal maintainer status is not documented anywhere I could find — mark uncertain, but the practical bus factor has improved from 1 to ~2.
- Scale: ~28.4k stars, ~1.7k forks, ~8.7k commits, ~1.5k open issues ([repo](https://github.com/wezterm/wezterm), fetched 2026-08-17).

## 2. Performance & fluidity

- Rendering: three `front_end` backends — `OpenGL` (default), `WebGpu` (Metal/Vulkan/DX12 via wgpu), `Software`. The default was flipped to WebGpu in Jan 2024 and reverted to OpenGL one release later — a churn signal ([front_end docs](https://wezterm.org/config/lua/config/front_end.html)). On Windows over RDP it auto-selects Software.
- Third-party 2026 comparisons consistently place WezTerm behind Ghostty/Alacritty/Kitty on rendering throughput — "2 to 5 times" worse than Ghostty depending on scenario ([dasroot.net comparison](https://dasroot.net/posts/2026/03/linux-terminal-emulators-alacritty-kitty-wezterm/), [scopir roundup](https://scopir.com/posts/best-terminal-emulators-developers-2026/)); latency tests are methodology-dependent but generally rank it above (worse than) foot/Alacritty ([dev.to latency measurement](https://dev.to/lkhrs/measuring-terminal-latency-26m7)). No first-party benchmark claims — the project doesn't sell speed.
- Startup on Windows is the standout pathology: reports of 1.5 s ([#5884](https://github.com/wezterm/wezterm/issues/5884)), 15–50 s in `portable_pty::cmdbuilder` and local GUI-socket setup ([#7782](https://github.com/wezterm/wezterm/issues/7782)), up to minutes on Win11 ([#7753](https://github.com/wezterm/wezterm/issues/7753)); persists with empty config and software rendering. Older threads: [#2066](https://github.com/wezterm/wezterm/issues/2066), [#6254](https://github.com/wezterm/wezterm/issues/6254).
- Repaint behavior has been observed to paint multiple times per frame with visible flash ([discussion #751](https://github.com/wez/wezterm/discussions/751)); nightly-only cursor/screen flicker on Windows, notably in PowerShell ([#5865](https://github.com/wezterm/wezterm/issues/5865)); "becomes slow after some time" ([#6925](https://github.com/wezterm/wezterm/issues/6925)).

## 3. Native Windows integration

- Requires Windows 10 1809+ (ConPTY); ships Inno Setup installer + portable ZIP with a "thumb-drive mode" (`wezterm.lua` beside the exe) ([install/windows](https://wezterm.org/install/windows.html), [config files](https://wezterm.org/config/files.html)).
- Backdrops: `win32_system_backdrop = Auto|Disable|Acrylic|Mica|Tabbed` plus `win32_acrylic_accent_color` for pre-22621 builds — richer named surface than noctty's tabbed-only blur ([docs](https://wezterm.org/config/lua/config/win32_system_backdrop.html)). But buggy in practice: phantom window buttons ([#5348](https://github.com/wezterm/wezterm/issues/5348)), visual artifacts ([#6111](https://github.com/wezterm/wezterm/issues/6111)), "not working" reports ([#4145](https://github.com/wezterm/wezterm/issues/4145), [#6265](https://github.com/wezterm/wezterm/issues/6265)).
- **No "default terminal application" registration** — open feature request asking for `IConsoleHandOff`/`ITerminalHandoff` COM registration; earlier asks were closed/deleted ([#7534](https://github.com/wezterm/wezterm/issues/7534)).
- **No native ARM64 Windows build** — the installer merely stopped refusing to install the x64 binary under emulation ([PR #2746](https://github.com/wezterm/wezterm/pull/2746)); native compile fails (freetype/neon) ([#6350](https://github.com/wezterm/wezterm/issues/6350), [discussion #7575](https://github.com/wezterm/wezterm/discussions/7575)).
- WSL: WSL domains bridge the Win32 GUI to distros via AF_UNIX sockets over shared filesystem paths; documented caveats — AF_UNIX interop is WSL1-only, and socket security checks are bypassed on NTFS volumes ([multiplexing](https://wezterm.org/multiplexing.html)). WSL distros auto-populate the launcher.
- No evidence of Snap Layouts work beyond standard frames, jump lists, or taskbar progress (absence-of-evidence, marked uncertain). Toast notifications exist via OSC 9 / iTerm2-style notify ([escape sequences](https://wezterm.org/escape-sequences.html)). Font rendering uses its own FreeType/HarfBuzz stack, not DirectWrite/ClearType — the root of the "looks different on Windows" complaints (§9).

## 4. Terminal capability

Per [escape-sequences](https://wezterm.org/escape-sequences.html) (self-described "living document"):
- Solid: OSC 8 hyperlinks, OSC 52 clipboard, OSC 133 semantic prompt/output zones, DEC 2026 synchronized output, comprehensive mouse reporting, bracketed paste, iTerm2 toast/file protocols (OSC 9/1337).
- Graphics: Sixel "preliminary and incomplete"; iTerm2 images functional but incomplete; **Kitty graphics is opt-in** (`enable_kitty_graphics`) and architecturally non-conformant — placements are mapped to cells at placement time, so overwriting cells "pokes holes" that kitty wouldn't show ([#3817 "horribly non-conformant"](https://github.com/wezterm/wezterm/issues/3817), [#986](https://github.com/wezterm/wezterm/issues/986)).
- Kitty keyboard protocol: opt-in via `enable_kitty_keyboard`, with reported encoding discrepancies vs kitty ([#4785](https://github.com/wezterm/wezterm/issues/4785), [key-encoding docs](https://wezterm.org/config/key-encoding.html)).
- Nightly hardening: DECRQCRA (checksum-rectangular-area) disabled by default "to prevent silent screen scraping" ([changelog](https://wezterm.org/changelog.html)).
- Scrollback: searchable (Ctrl+Shift+F), but held entirely in RAM with no disk spill or ring buffer — directly implicated in the memory complaints ([scrollback docs](https://wezterm.org/scrollback.html), §9).
- Shell integration: OSC 7/133-based semantic zones; tmux control mode "currently incomplete" ([escape-sequences](https://wezterm.org/escape-sequences.html)).

## 5. Workflow features

- Tabs, splits, multiple windows, **workspaces** (named session groups), launcher menu, **command palette**, **quick select mode** (regex-hint text capture, keyboard-only), **copy mode** (modal keyboard selection), searchable scrollback, key tables (modal keybinding layers) ([features](https://wezterm.org/features.html)).
- Multiplexing is the crown jewel ([multiplexing](https://wezterm.org/multiplexing.html)): domains — local, **SSH** (auto-populated from `~/.ssh/config`; requires wezterm on the remote), **TLS** (certs bootstrapped over SSH, reconnectable), **Unix** (works on Windows via AF_UNIX), **WSL**. `wezterm-mux-server` keeps panes alive independent of the GUI; `wezterm connect <domain>` reattaches with scrollback intact. This gives tmux-like process persistence across GUI restarts — something noctty's session restore explicitly does not do.
- Built-in SSH client (`wezterm ssh`) and serial-port support for embedded work ([features](https://wezterm.org/features.html)).
- **No built-in layout save/restore across reboots** — long-open request ([#3237](https://github.com/wezterm/wezterm/issues/3237)); filled by third-party Lua plugins: [resurrect.wezterm](https://github.com/MLFlexer/resurrect.wezterm) (periodic state save, restores layout+text), [wezterm-sessions](https://github.com/abidibo/wezterm-sessions/), [wezterm-session-manager](https://github.com/danielcopper/wezterm-session-manager).
- No first-class quake/dropdown mode or broadcast-input toggle; both are community-Lua territory (uncertain: absence based on docs/feature page, not exhaustive).

## 6. Reliability & quality signals

- Dominant issue themes: Windows startup latency (§2), memory growth/leaks — >5 GiB ([#1626](https://github.com/wezterm/wezterm/issues/1626)), 1.4 GB RSS in 18 h ([#7442](https://github.com/wezterm/wezterm/issues/7442)), hashbrown leaks ([#3815](https://github.com/wezterm/wezterm/issues/3815)), unbounded mux PDU allocation causing OOM ([#7527](https://github.com/wezterm/wezterm/issues/7527)) — plus nightly-only rendering regressions ([#5865](https://github.com/wezterm/wezterm/issues/5865)).
- Release stability paradox: the stable release (2024-02) is well-regarded but ancient; all fixes live in nightlies, which carry regressions. Users must choose between stale-stable and moving-nightly.
- "Is this project no longer being updated?" filed Dec 2025 ([#7451](https://github.com/wezterm/wezterm/issues/7451)) and "Please keep creating stable releases" ([#7825](https://github.com/wezterm/wezterm/issues/7825)) capture the community's confidence problem — even while commits land near-daily ([commits](https://github.com/wezterm/wezterm/commits/main)).
- CI produces continuous nightly builds across platforms plus a Copr repo ([install/linux](https://wezterm.org/install/linux.html)); 1.5k open issues against a spare-time team.

## 7. Configuration & extensibility

The category WezTerm owns outright:
- Single Lua file, ~250+ options, `config_builder()` with typo diagnostics, layered discovery (CLI flag → env var → portable exe-adjacent → XDG → `~/.wezterm.lua`), automatic live reload plus manual Ctrl+Shift+R, bad config falls back to built-in defaults with a visible error rather than dying ([config files](https://wezterm.org/config/files.html)).
- Runtime scriptability: event system (GUI lifecycle, mux events), callbacks as keybinding actions, per-window `window:set_config_overrides()`, CLI overrides (`wezterm --config key=value`), `wezterm.serde` (JSON/TOML/YAML) in nightly ([changelog](https://wezterm.org/changelog.html)).
- Plugin system: `wezterm.plugin.require("https://github.com/...")` git-clones Lua packages exposing `apply_to_config`; `update_all()` for upgrades; a community awesome-list exists ([plugins docs](https://wezterm.org/config/plugins.html)). This is how session-restore, tab bars, and workspace switchers ship without core involvement.
- Documented footgun: config is evaluated multiple times per process, so side effects (spawning processes) multiply ([config files](https://wezterm.org/config/files.html)).
- Font handling is unusually deep: bundled JetBrains Mono + Nerd Font Symbols + Noto Color Emoji (TUI glyphs work with zero config), ordered `font_with_fallback`, `font_rules` for bold/italic variants, HarfBuzz shaping features, FreeType hinting knobs, and `wezterm ls-fonts --text "..."` for glyph-level shaping/fallback debugging ([fonts docs](https://wezterm.org/config/fonts.html)).

## 8. Packaging & adoption

- Windows: setup.exe (Inno Setup, registers PATH), portable ZIP, `winget install wez.wezterm`, Scoop (extras), Chocolatey ([install/windows](https://wezterm.org/install/windows.html)). No evidence the Windows binaries are Authenticode-signed (uncertain — not documented; no signing infrastructure visible).
- Update mechanism: `check_for_updates` polls GitHub every 24 h and **only notifies** — no download/staging/apply; explicitly collects no data ([check_for_updates docs](https://wezterm.org/config/lua/config/check_for_updates.html)).
- The stale-stable problem is a distribution problem: Scoop/winget stable channels serve the Feb 2024 build, so a mainstream Windows user is 2.5 years behind ([#7825](https://github.com/wezterm/wezterm/issues/7825)).
- Docs site (wezterm.org) is large and genuinely good — per-option pages with version annotations — but "since: nightly" annotations mean much of the documented surface isn't in any stable release.
- Momentum: ~28.4k stars, healthy discussions/Matrix, near-daily commits, but zero stable releases in 30 months ([releases](https://github.com/wezterm/wezterm/releases)).

## 9. What users complain about

1. **No stable releases / is it dead?** — [#7825](https://github.com/wezterm/wezterm/issues/7825), [#7451](https://github.com/wezterm/wezterm/issues/7451).
2. **Windows startup latency** — seconds to minutes; multiple open issues with traces pointing at pty/mux-socket setup ([#7782](https://github.com/wezterm/wezterm/issues/7782), [#7753](https://github.com/wezterm/wezterm/issues/7753)).
3. **Memory usage** — all-RAM scrollback plus leaks; >5 GiB reports ([#1626](https://github.com/wezterm/wezterm/issues/1626), [#7527](https://github.com/wezterm/wezterm/issues/7527)).
4. **Font rendering is divisive** — "I really _want_ to like WezTerm but the font rendering just looks bad compared to…" ([HN](https://news.ycombinator.com/item?id=41227750), [#5075](https://github.com/wezterm/wezterm/issues/5075)); yet others choose WezTerm *because* its FreeType stack is consistent across fractional-scaled displays ([discussion #5400](https://github.com/wezterm/wezterm/discussions/5400)). Non-native rasterization cuts both ways on Windows.
5. **Raw throughput/latency behind Ghostty/Alacritty** — third-party 2025–2026 roundups (§2).
6. **Kitty graphics non-conformance** for TUI image tooling ([#3817](https://github.com/wezterm/wezterm/issues/3817)).
7. Nightly-channel regressions (flicker) forcing a stability-vs-fixes tradeoff ([#5865](https://github.com/wezterm/wezterm/issues/5865)).

## 10. Lessons for noctty

### Does well (adopt-candidates)

Judged against [docs/status.md](../../../docs/status.md) / [windows-capability-matrix.md](../../../docs/windows-capability-matrix.md):

1. **Process-surviving sessions (mux concept).** noctty's `window-save-state` restores layout but not processes. WezTerm's mux-server + domains keeps shells alive across GUI restarts and reattaches with scrollback. Even a local-only "mux domain" (or ConPTY-handle survival across restarts) would leapfrog every Windows-native competitor on PRODUCT.md's "session layout survives restarts" promise.
2. **Scripting/automation surface.** noctty has only allowlisted `+perform-action` IPC. WezTerm's Lua events, callback keybindings, and git-fetched plugins let users self-serve features (session restore itself shipped as a plugin). An expanded, stable automation API — even without embedding a language — is the biggest capability gap.
3. **Quick select + copy mode.** Keyboard-driven regex capture of hashes/paths/URLs and modal selection; pure keyboard-first wins that status.md doesn't list, cheap relative to payoff.
4. **Font fallback UX and tooling.** Bundled Nerd Font symbols + emoji fallback for zero-config TUI glyph coverage, and a `ls-fonts --text` style shaping/fallback debugger. noctty has no documented equivalent diagnostic.
5. **SSH-aware workflow.** Auto-populating launcher/profiles from `~/.ssh/config` (noctty's profile picker covers local shells + WSL only); WezTerm's built-in ssh client shows the demand.
6. **Named backdrop surface.** `win32_system_backdrop = Acrylic|Mica|Tabbed` + pre-22621 acrylic accent color vs noctty's on/off tabbed-only blur.
7. **CLI config overrides** (`--config key=value`) for one-off experiments without editing the file.
8. **Workspaces** as named groupings above windows/tabs for project switching.

### Does badly (avoid / exploit)

1. **Stale stable channel.** 30 months without a stable release turned a healthy project into one users file "is this dead?" issues against, and package managers into distributors of old bugs. noctty already has signed, checksummed GitHub releases + winget/Scoop — keep cadence regular and visible; treat release discipline as a marketed feature.
2. **Windows as a port.** Minute-scale startup, mux-socket setup stalls, nightly flicker, no default-terminal handoff ([#7534](https://github.com/wezterm/wezterm/issues/7534)), no native ARM64. noctty ships native ARM64 today — say so loudly; add `IConsoleHandOff`/default-terminal registration to beat WezTerm *and* match Windows Terminal.
3. **Unbounded memory.** All-RAM scrollback and mux-layer leaks produce GiB-scale RSS. Bound and page scrollback; make memory a benchmarked, advertised number.
4. **Opt-in, non-conformant protocol support.** Kitty graphics/keyboard behind flags and diverging from spec breaks TUI tooling. noctty inherits Ghostty's conformant implementations — protect that with the Win32 VT-conformance doc as a public artifact.
5. **Renderer default churn** (WebGpu default flipped then reverted within days). A cautionary tale for noctty's planned ARB-context OpenGL migration: stage behind opt-in, keep rollback.
6. **Power-tool config as the only front door.** Lua's multiple-evaluation footguns and 250-option sprawl create a newcomer cliff that noctty's native settings window + universal palette already answer — that pairing is the differentiator; don't dilute it.

### Blind-spot candidates (no category in PRODUCT.md)

1. **Remote development as a product surface.** PRODUCT.md scopes to "PowerShell and WSL," but WezTerm's SSH/TLS domains serve the same benchmark user the moment they touch a dev server or VM. No noctty category covers remote sessions, reconnect semantics, or remote persistence.
2. **User extensibility as an ecosystem.** Not just scripting: WezTerm's git-URL plugin distribution created a community that builds missing features (session restore, tab bars) without maintainer time — a leverage model PRODUCT.md has no slot for, and one that matters for a solo-maintained fork.
3. **Serial/embedded workflows** (COM ports, Arduino) — a real Windows-developer niche wholly absent from PRODUCT.md.
4. **Portable "thumb-drive" mode** — config discovered next to the exe; noctty has a portable ZIP but pins config to `%LOCALAPPDATA%`. Locked-down corporate machines make this a genuine Windows persona.
5. **Terminal-side security posture as a feature** — WezTerm disabling DECRQCRA by default to block screen scraping; PRODUCT.md has privacy plumbing (local crash dumps, redacted diagnostics) but no category for VT-level anti-exfiltration decisions.
6. **tmux control mode (`tmux -CC`) interop** — incomplete in WezTerm but present as an ambition; relevant to WSL-heavy users who already live in tmux.
