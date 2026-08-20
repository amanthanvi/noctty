# Tabby (Eugeny/tabby) — Deep Dive

Researched 2026-08-17. Evidence: GitHub repo/issues/releases, tabby.sh, DeepWiki architecture mirror, third-party 2026 reviews, HN. No hands-on claims.

## Executive summary

Tabby is a ~74k-star MIT Electron/Angular/xterm.js terminal + SSH/serial/telnet client that wins users *despite* its weight because it bundles a PuTTY/mRemoteNG-class connection manager, an encrypted secrets vault, a GUI-first settings surface, and an npm plugin system into one cross-platform app ([README](https://github.com/Eugeny/tabby)). Its Windows story is broad but shallow: every shell (PowerShell, WSL, Cygwin, Cmder, Clink completion), portable mode, quake mode — yet no default-terminal registration and Electron-grade startup and RAM. Performance is its permanent open wound: 200–400MB idle RAM, documented 30–60s first-tab startup pathologies, 740MB GPU RAM vs Windows Terminal's 32MB, and a 15GB memory-leak report ([#10857](https://github.com/Eugeny/tabby/issues/10857), [discussion #5667](https://github.com/Eugeny/tabby/discussions/5667), [#10414](https://github.com/Eugeny/tabby/issues/10414)). Governance is effectively one person (Eugeny); the companion tabby-web sync service is unmaintained for lack of sponsors, and a 2026 reviewer notes the plugin ecosystem "has gone quiet" ([tabby-web README](https://github.com/Eugeny/tabby-web), [MOLTamp](https://moltamp.com/blog/best-tabby-terminal-plugins-2026/)). Core lesson for winghostty: Tabby proves demand for *managed connections + GUI config + secrets* on Windows is huge, and that users will pay a heavy performance tax to get it — winghostty can offer the workflow value without the tax.

## 1. Identity & strategy

- **What**: "A terminal for a more modern age" — cross-platform (Win/macOS/Linux) terminal emulator *and* SSH/telnet/serial client, explicitly pitched as "an alternative to Windows' standard terminal (conhost), PowerShell ISE, PuTTY, macOS Terminal.app" ([README](https://github.com/Eugeny/tabby)). Formerly "Terminus".
- **Target**: developers and ops/network engineers who juggle local shells plus many remote hosts and want one GUI app for all of it. The serial client explicitly targets embedded/hardware folks.
- **Differentiators (stated)**: integrated SSH connection manager with jump hosts/X11/port forwarding, encrypted secrets container, serial with hex I/O and auto-reconnect, Zmodem, portable mode, plugins, themes ([README](https://github.com/Eugeny/tabby)).
- **Honest positioning**: the README itself concedes it uses more RAM than ConEmu/Alacritty — the project openly accepts the Electron tax as the price of features.
- **Governance/bus factor**: single dominant maintainer (Eugeny), funded via OpenCollective/Ko-fi. The companion tabby-web project's README says the developer "no longer has time to work on it" and it survives only on merged community PRs ([tabby-web](https://github.com/Eugeny/tabby-web)). High bus-factor risk despite 74k stars. (Exact commit-share not verifiable this session — contributor graph didn't load; marked as inference from repo authorship patterns.)
- **License**: MIT. ~74k stars, ~4.2k forks, ~6.5k commits ([repo](https://github.com/Eugeny/tabby)).

## 2. Performance & fluidity

- **Architecture**: Electron shell, Angular UI, xterm.js terminal core with the WebGL addon for GPU-accelerated cell rendering ([DeepWiki architecture](https://deepwiki.com/Eugeny/tabby/1.1-features-and-capabilities)). Damage/throughput model is therefore xterm.js's, inside a Chromium compositor — two compositors deep before pixels hit DWM.
- **Measured pain**:
  - Idle RAM 200–400MB typical, vs 50–100MB for native terminals ([MakerStack 2026 review](https://makerstack.co/reviews/tabby-terminal-review/)).
  - GPU memory: user-measured ~740MB GPU RAM for 3 cmd tabs vs Windows Terminal's ~32MB ([discussion #5667](https://github.com/Eugeny/tabby/discussions/5667)).
  - Memory leak reports up to 15GB after days-long sessions ([#10414](https://github.com/Eugeny/tabby/issues/10414)).
  - Startup: a long lineage of issues — "30–60 seconds to open first tab" ([#10857](https://github.com/Eugeny/tabby/issues/10857)), "opening new tab takes over 20 seconds" ([#5872](https://github.com/Eugeny/tabby/issues/5872)), "make startup faster" ([#6253](https://github.com/Eugeny/tabby/issues/6253)), Windows-specific slow open ([#2435](https://github.com/Eugeny/tabby/issues/2435)).
- **No published latency/throughput benchmarks** from the project itself; the 2026 review verdict is "rendering lags behind GPU-accelerated terminals; sluggish with large output buffers" ([MakerStack](https://makerstack.co/reviews/tabby-terminal-review/)).
- HN consensus (2023 launch thread, still the reference discussion): "Writing a terminal emulator in Electron just seems like a bonkers idea" — yet the app kept growing anyway ([HN](https://news.ycombinator.com/item?id=36607323)).

## 3. Native Windows integration

- **Shell coverage is Tabby's Windows strength**: PowerShell, PowerShell Core, WSL, Git-Bash, Cygwin, MSYS2, Cmder, CMD, with tab-completion via Clink and Windows OpenSSH Agent + Pageant support ([DeepWiki](https://deepwiki.com/Eugeny/tabby/1.1-features-and-capabilities), [README](https://github.com/Eugeny/tabby)).
- **ConPTY**: uses Windows ConPTY for local shells (standard for non-conhost terminals); the project cites ConPTY as the reason sixel can't work on Windows ([vscode #198622 cross-ref](https://github.com/microsoft/vscode/issues/198622), [tabby #7063](https://github.com/Eugeny/tabby/issues/7063)).
- **Not a default-terminal candidate**: long-standing open request to register as Windows 11 default terminal app ([#4882](https://github.com/Eugeny/tabby/issues/4882)); Explorer "open here" integration is a manual registry hack that users struggle with ([discussion #6396](https://github.com/Eugeny/tabby/discussions/6396)).
- **No evidence of** Snap Layouts polish, jump lists, taskbar progress, or native notifications beyond Electron defaults (absence of docs/issues treated as absence of feature — low-medium confidence).
- **Portable mode**: first-class — drop a `data` folder next to the exe ([README](https://github.com/Eugeny/tabby)); also a Portapps build ([portapps](https://portapps.io/app/tabby-portable/)). Popular with locked-down-corporate users.
- **Quake mode + global hotkey**: dropdown console summonable system-wide ([DeepWiki](https://deepwiki.com/Eugeny/tabby/1.1-features-and-capabilities)).
- **Windows chrome**: custom web-rendered chrome (acrylic-style options), not native; reliability issues on Win11 24H2 startup reported ([#10284](https://github.com/Eugeny/tabby/issues/10284), [#10579](https://github.com/Eugeny/tabby/issues/10579)).
- **ARM64**: Windows ARM64 builds are published in releases (Electron supports it) — medium confidence; not independently verified this session.

## 4. Terminal capability

- **VT depth**: xterm.js — "VT220 with extensions" per README; solid for everyday TUIs but shallower than Ghostty's core (which winghostty inherits). Full Unicode incl. double-width; ligatures; bracketed paste ([README](https://github.com/Eugeny/tabby), [DeepWiki](https://deepwiki.com/Eugeny/tabby/1.1-features-and-capabilities)).
- **Graphics**: none shipping. Sixel requests open since 2022 ([#6032](https://github.com/Eugeny/tabby/issues/6032), [#7063](https://github.com/Eugeny/tabby/issues/7063)); Kitty graphics protocol request open and among top-voted ([#9819](https://github.com/Eugeny/tabby/issues/9819)). winghostty already ships Kitty graphics — a direct capability win.
- **Hyperlinks/clipboard**: xterm.js link handling; clipboard OSC support not prominently documented (uncertain — likely partial).
- **Shell integration**: no OSC 133 prompt-marks/command-duration story comparable to Ghostty/WezTerm; Tabby's "integration" means shell *profiles* and Clink completion, not semantic prompt zones (medium confidence from docs absence + issue #632 asking for output highlighting).
- **Zmodem file transfer** over SSH — a capability winghostty has no analog for ([README](https://github.com/Eugeny/tabby)).
- **Search & scrollback**: in-buffer search exists; scrollback is xterm.js in-memory (no unlimited/disk-backed scrollback). New in 1.0.234: "export terminal contents to file" ([release notes](https://github.com/Eugeny/tabby/releases/tag/v1.0.234)).

## 5. Workflow features

The section that explains 74k stars:

- **SSH connection manager**: saved profiles in tree/groups (profile *tree view* added v1.0.235), jump-host chaining, X11 + port forwarding, agent forwarding, login scripts, auto-sudo-password, `tabby://` URL scheme for deep-linking connections (v1.0.231) ([releases](https://github.com/Eugeny/tabby/releases), [README](https://github.com/Eugeny/tabby)).
- **Encrypted secrets vault**: master-passphrase container for SSH passwords/keys — Slant reviewers repeatedly cite this as the reason to pick Tabby over mRemoteNG/PuTTY ([Slant](https://www.slant.co/versus/26039/34714/~tabby-terminal_vs_mremoteng)).
- **Serial + telnet**: saved serial connections, readline, hex I/O, auto-reconnect — owns the embedded-dev niche no fast terminal serves ([README](https://github.com/Eugeny/tabby)).
- **Tabs/splits**: tabs, split panes, pinned tabs (v1.0.235), per-tab activity/progress notifications; tab persistence restores open tabs across restarts (medium confidence — "recover tabs" setting; terminal contents not restored). Drag-tab-to-new-window is the single most-upvoted open issue ([#581](https://github.com/Eugeny/tabby/issues/581)) — winghostty also lacks cross-window drag, worth noting demand.
- **Quake mode + global hotkey**, fully configurable multi-chord hotkeys, incl. mouse-wheel-as-hotkey (v1.0.235).
- **SFTP**: built-in SFTP tab/panel for SSH sessions with upload/download ([releases](https://github.com/Eugeny/tabby/releases/tag/v1.0.233)).
- **No command palette** in the Raycast/VS Code sense; no tmux -CC (top-voted request [#5030](https://github.com/Eugeny/tabby/issues/5030)); broadcast-input exists only via community plugins (low confidence).

## 6. Reliability & quality signals

- **~2.7k open issues** ([issue tracker](https://github.com/Eugeny/tabby/issues)) — huge backlog for a one-maintainer project.
- **Dominant themes**: startup/latency pathologies (§2), SSH regressions (auth failures introduced in 1.0.222, [#10347](https://github.com/Eugeny/tabby/issues/10347); russh SFTP zlib upload failures [#10780](https://github.com/Eugeny/tabby/issues/10780); slow SFTP [#8972](https://github.com/Eugeny/tabby/issues/8972)), memory leaks, Windows startup failures on new OS builds ([#10284](https://github.com/Eugeny/tabby/issues/10284)).
- **Security posture**: 2026 releases repeatedly ship shell-injection/path-traversal/URI-handler fixes (v1.0.232–235, [releases](https://github.com/Eugeny/tabby/releases)) — the price of URL schemes + web runtime + plugin surface. Rapid patch turnaround is a genuine strength; the recurring vuln classes are structural.
- **Release cadence**: bursts — 4 releases in May 2026, then July; historically weeks-to-months. Perpetual `1.0.x` versioning, no beta channel.
- No public test/CI conformance story comparable to Ghostty's VT test suite (absence-based, medium confidence).

## 7. Configuration & extensibility

- **GUI-first config**: everything — profiles, hotkeys, appearance, SSH, vault — is editable in a settings UI; backing store is a YAML config file (config.yaml) that can be hand-edited/synced (file-format detail: medium confidence). This "GUI first, file underneath" model is exactly what winghostty's native settings window converges on.
- **Plugins**: npm packages (`tabby-plugin` keyword) discovered/installed from an in-app Plugin Manager; can add connection types, UI, settings panels ([HACKING.md](https://github.com/Eugeny/tabby/blob/master/HACKING.md), [DeepWiki plugin dev](https://deepwiki.com/Eugeny/tabby/9.2-plugin-development)). Notable: Docker containers-as-connections, SFTP panel, workspace manager, save-output, AI command suggesters, theme packs (Catppuccin/Gruvbox).
- **Ecosystem health**: declining — "plugin-friendly… but its plugin ecosystem has gone quiet" ([MOLTamp 2026](https://moltamp.com/blog/best-tabby-terminal-plugins-2026/)). Plugins also multiply the security and memory surface.
- **Config sync**: the official story collapsed. tabby-web (browser Tabby + sync backend) is unmaintained; sync now depends on self-hosting tabby-web or third-party plugins targeting S3/Cloudflare Workers ([tabby-web](https://github.com/Eugeny/tabby-web), [tabby-cloud-sync-settings](https://github.com/niceit/tabby-cloud-sync-settings), [community CF-workers service](https://tabby.waynecommand.com/)). Users keep asking for self-owned sync ([#10993](https://github.com/Eugeny/tabby/issues/10993)).
- Live reload: config changes apply from the GUI immediately; file-edit reload behavior not verified.

## 8. Packaging & adoption

- **Channels**: GitHub releases (installer + portable zip), winget (`Eugeny.Tabby`), Chocolatey, Scoop, Homebrew, deb/rpm ([winget.run](https://winget.run/pkg/Eugeny/Tabby), [Chocolatey](https://community.chocolatey.org/packages/tabby)). Chocolatey lagging at 1.0.223 vs 1.0.235 — third-party repackaging drift.
- **Update mechanism**: built-in Electron auto-updater (standard); no evidence of Authenticode/signing friction complaints at scale (uncertain).
- **Docs**: thin — tabby.sh is a landing page; deep knowledge lives in the wiki/READMEs and community cheat-sheets. Notably weaker than the feature surface deserves; onboarding relies on the GUI being self-explanatory (which, per reviews, it largely is).
- **Momentum**: ~74k stars, active 2026 releases, but single-maintainer throughput caps it; top feature requests (mosh, tmux -CC, Kitty graphics, tab tear-off) sit open for years.

## 9. What users complain about

1. **RAM/GPU-RAM/leaks** — 300MB+ idle, 740MB GPU vs WT's 32MB, 15GB leak reports ([#5667](https://github.com/Eugeny/tabby/discussions/5667), [#10414](https://github.com/Eugeny/tabby/issues/10414), [MakerStack](https://makerstack.co/reviews/tabby-terminal-review/)).
2. **Startup and interaction latency** — 20–60s tab-open pathologies, 1–10s hangs after updates ([#10857](https://github.com/Eugeny/tabby/issues/10857), [#10665](https://github.com/Eugeny/tabby/issues/10665), [#9344](https://github.com/Eugeny/tabby/issues/9344)).
3. **Electron itself** — battery, principle, "too competitive a market for an Electron terminal" ([HN](https://news.ycombinator.com/item?id=36607323)).
4. **SSH regressions** breaking daily-driver remote workflows ([#10347](https://github.com/Eugeny/tabby/issues/10347), [#10780](https://github.com/Eugeny/tabby/issues/10780)).
5. **Missing depth**: no sixel/Kitty graphics, no mosh, no tmux -CC, no tab tear-off, no first-party sync anymore (top-voted issues, §5/§7).
6. **Windows-version fragility**: fails to launch after some Windows 11 updates ([#10284](https://github.com/Eugeny/tabby/issues/10284), [#9448](https://github.com/Eugeny/tabby/issues/9448)).

## 10. Lessons for winghostty

### Does well (adopt-candidates)

Judged against docs/status.md + windows-capability-matrix.md:

1. **SSH connection manager as a first-class profile type** — saved hosts with groups/tree, jump hosts, port forwarding, agent forwarding. winghostty's profile picker knows local shells + WSL only; Tabby proves the "remote hosts are profiles too" model is the #1 adoption driver on Windows. Even a lean version (saved `ssh` command profiles + `%USERPROFILE%\.ssh\config` ingestion into the universal palette) captures most value at near-zero weight.
2. **Encrypted secrets vault** (master-passphrase, or better: Windows Hello/Credential Manager–backed) — repeatedly the cited reason users choose Tabby over PuTTY/mRemoteNG.
3. **Quake mode / global-hotkey dropdown terminal** — winghostty has no quick-terminal; Tabby, WT, and upstream Ghostty (macOS) all treat it as core.
4. **Portable mode as a deliberate feature** (`data` dir next to exe) — winghostty has a portable ZIP but no portable *state* story and no ZIP updater apply; corporate locked-down users are a real Windows constituency.
5. **Per-tab activity/progress notification badges** — visible progress on background tabs matches PRODUCT.md's "keep progress visible" principle; winghostty has no equivalent.
6. **`app://` deep links for sessions** (`tabby://` scheme) — launch-into-profile URLs compose with launchers/scripts; cheap given winghostty's existing single-instance IPC.
7. **Pinned tabs + tab tear-off demand signal** — Tabby's most-upvoted issue is drag-tab-to-new-window; winghostty explicitly lacks cross-window OLE transfer. Demand is validated; shipping it is differentiation against both Tabby and WT.

### Does badly (avoid / exploit)

1. **The performance tax is permanent and structural** (Electron + xterm.js + Chromium compositor): 300MB idle, GPU-RAM bloat, multi-second startup. winghostty's headline claim — instantaneous native startup, tiny footprint — should be *benchmarked publicly against Tabby and WT*, because Tabby users cite exactly these numbers when leaving.
2. **Regression-prone releases with no beta channel** — SSH auth broke in a point release for daily-driver users. Exploit: winghostty's checksum+Authenticode staged updater and safe-mode/quarantine recovery are a credible "we don't brick your workflow" story; keep investing there.
3. **Single-maintainer + 2.7k open issues + abandoned sync service** — feature surface outran sustaining capacity. Avoid: don't ship services (sync!) or plugin surfaces you can't sustain; Tabby's dead tabby-web actively burns user trust.
4. **Security vulns from URL handlers + web runtime + npm plugins** (repeated 2026 injection/traversal fixes). winghostty's allowlisted-IPC + no-plugin-runtime posture is defensible — if it adds deep links or extensions, learn from Tabby's vuln classes first.
5. **Web chrome instead of native** — Win11-update launch breakage, no default-terminal registration, registry-hack Explorer integration. Exploit by doing the native things Tabby structurally can't: default-terminal handoff (IDefaultTerminalApp), Explorer context menu, jump lists.

### Blind-spot candidates (no category in PRODUCT.md)

1. **Remote connection management as a product pillar** — PRODUCT.md frames the benchmark user as PowerShell+WSL local; Tabby's entire success says Windows devs are *also* SSH-fleet operators. There is no PRODUCT.md category for remote hosts, saved connections, or secrets.
2. **Serial/COM-port workflows** — embedded developers on Windows are a durable niche (device flashing, USB-serial consoles) that keeps choosing Tabby/PuTTY; nothing in PRODUCT.md contemplates non-shell transports.
3. **Settings/profile sync across machines** — work desktop + laptop is normal; Tabby's sync collapse shows both the demand and the maintenance trap. A file-based, cloud-agnostic answer (config in a syncable dir + conflict-aware merge, which winghostty's revision-aware settings merge nearly is) would fill this without a service.
4. **File-transfer affordances** (SFTP panel, Zmodem, drag-out of files) — PRODUCT.md covers drag-and-drop *in* only.
5. **In-app extensibility/plugin economy** — Tabby shows a plugin manager drives community energy (Docker tabs, AI helpers, themes) but also drags in memory, security, and abandonment risk; PRODUCT.md has no stated position either way, and it should have an explicit one.
