# Field sweep: long-tail Windows terminals

Shallow sweep per ticket R10 (own format, not the full ten-section
rubric). One dense paragraph per product; payload lists first. All
claims research-sourced; today's reference date is 2026-08-17.

## Executive summary

The long tail splits into four stories: (1) **category drift** — Wave,
yaw, Termius and MobaXterm are turning "terminal" into an infrastructure
workspace (widgets, SSH/DB managers, AI, sync) that PRODUCT.md has no
category for; (2) **two corpses with lessons** — Fluent Terminal (UWP
platform bet, killed by Windows Terminal) and Hyper (44.7k stars,
effectively dormant) prove chrome-only differentiation and Electron
ceilings are fatal; (3) **idea donors** — Contour (modal input, daemon
sessions, VT standards leadership), Extraterm (output framing, scroll
minimap), mintty (Unicode currency, huge silent Git-Bash install base);
(4) **a direct threat the nine dives miss** — a swarm of community
`ghostty-windows` native ports (adilahmeddev `windows-apprt` lineage)
occupying winghostty's exact niche. Promotion candidates: Wave Terminal
and the ghostty-windows fork family.

## (a) Blind-spot candidates for synthesis

Things no PRODUCT.md category covers, ordered by judged importance:

1. **Durable/detachable sessions** — terminal *contents and processes*
   surviving UI restart or network drop (Contour daemon mode with
   local/network attach; Wave's "durable SSH sessions" v0.14.0,
   2026-02-10; tmux/zellij-under-WSL culture). winghostty's
   `window-save-state` explicitly does *not* restore contents or
   children (docs/status.md) — the long tail shows users now expect
   more.
2. **Fork-swarm / namespace risk** — multiple `ghostty-windows` native
   ports ship today; upstream could bless one, and users cannot tell
   forks apart. PRODUCT.md has no strategic category for competing
   forks of the same upstream in the same niche.
3. **Block-structured scrollback without AI** — Extraterm's shell-
   integration "framing" (collapse, delete, re-use command output as
   input) predates Warp's blocks and needs no cloud; treating past
   command output as an addressable object is a workflow primitive, not
   an AI feature.
4. **Modal (vi-like) keyboard input** for select/copy/navigate
   (Contour's headline feature; kitty's scrollback pager) — pure
   keyboard-first territory PRODUCT.md never mentions.
5. **Enterprise/OS auth surfaces** — smart-card via Microsoft CryptoAPI
   (MobaXterm 26.4), FIDO2 keys, Windows Hello biometrics (Termius) for
   SSH workflows.
6. **Encrypted cross-device sync + mobile companion** (Termius vault,
   team sharing) — continuity of config/hosts across machines.
7. **Scrollback minimap** — Extraterm's "Scroll Map" (v0.80, 2025-01)
   as a navigation aid for deep scrollback.
8. **VT-standards participation as strategy** — Contour maintains
   `terminal-unicode-core` and VT-extension spec repos (active April
   2026); spec-shaping earns credibility and conformance-test
   attention (cf. jeffquast's 2025 survey naming Ghostty/kitty
   champions).
9. **Quake-mode global-hotkey terminal** — Wave added it (v0.14.5,
   2026-04-16); Fluent Terminal had it years ago; upstream Ghostty has
   quick-terminal on macOS/Linux. Rubric §5 names it, so deep dives
   may catch it, but winghostty's status.md has no such surface.
10. **WSLg as a competitor vector** — kitty and other Linux terminals
    run on Windows 11 via WSLg with no port; the rival set is not only
    native apps.
11. **Accessibility beyond screen readers** — mintty ships a
    text-to-speech output configuration example (2026 changelog); the
    long tail experiments where big terminals don't.

## (b) Promotion candidates for a full deep dive

- **Wave Terminal** — 22.1k stars, Apache-2.0, active monthly releases
  into 2026, real Windows support, and the only long-tail product
  defining a genuinely distinct category (block workspace + durable
  remote sessions + AI). If the roadmap must answer "what if the
  terminal becomes a workspace?", Wave is the case study.
- **The ghostty-windows fork family** (adilahmeddev `windows-apprt`
  lineage and its many mirrors) — same upstream, same platform, same
  users as winghostty; ~34k lines of Windows-specific code, D3D11
  primary renderer, DirectWrite fonts, claimed daily-driver stability
  since March 2026. A deep dive should establish real capability,
  activity, and whether consolidation/blessing risk is live. (Caveat:
  several repos look like near-identical clones of one another;
  activity and quality are unverified — see paragraph below.)
- Not promoted: MobaXterm and Termius are SSH-workspace products whose
  lessons are captured here; Hyper and Fluent are dormant/dead;
  Contour, Extraterm, mintty are idea donors, not rivals for the
  benchmark user.

## Product paragraphs

### Wave Terminal

Open-source (Apache-2.0), Electron front end with a Go backend, 22.1k
stars, Windows 10 1809+ **x64 only** — no Windows ARM64, which
winghostty ships ([repo](https://github.com/wavetermdev/waveterm)). It
replaces linear scrollback with a tiled workspace of blocks/widgets:
terminals, remote file editor with syntax highlighting, file previews
(markdown/images/CSV/PDF), embedded browser, AI chat (OpenAI, Claude,
Azure, Ollama), a `wsh` CLI to script the workspace, and OS-native
secret storage. 2026 releases are brisk: v0.14.0 (2026-02-10) added
durable SSH sessions that survive network interruption; v0.14.5
(2026-04-16) added a process-viewer widget and quake-mode global hotkey
([release notes](https://docs.waveterm.dev/releasenotes)). Third-party
2026 reviews report the Electron cost — 400–800 MB memory, resize lag —
and judge the AI layer "good but generic," a thin default-OpenAI wrapper
([moltamp review](https://moltamp.com/blog/wave-terminal-review-2026/)).
Lesson pair: the workspace/durable-session ideas are real; the
performance floor is winghostty's opening.

### Fluent Terminal

Dead. UWP + xterm.js, 9.6k stars, explicitly "no longer being
maintained"; the maintainer's README recommends Windows Terminal, which
"contains everything I originally set out to achieve … and more"
([repo](https://github.com/felixse/FluentTerminal)). In its day it
pioneered on-Windows features winghostty still lacks: quake mode,
Explorer context-menu integration, SSH/Mosh profiles, theme
import/export. Two lessons: a solo project differentiating on chrome
dies the day the platform vendor ships a competent default; and a bet
on a fragile Windows UI framework (UWP sandboxing, brokered ConPTY)
ages badly — evidence for winghostty's raw-Win32 choice. Its graceful,
explicit sunset note is also a governance model worth copying if it
ever comes to that.

### Contour

Alive and quietly important: C++23, Apache-2.0, ~3k stars, commits
within days of this sweep and bugfix release notes through 2026
([repo](https://github.com/contour-terminal/contour),
[release notes](http://contour-terminal.org/release-notes/)). Runs on
Windows 10+ via ConPTY with installer and portable zip, though Windows
is clearly a secondary platform. Distinctives the nine dives won't
surface: **vi-like modal input**, **daemon mode with persistent
sessions and local/network attach**, Sixel *and* ReGIS graphics, VT
extensions (synchronized updates, buffer capture), and stewardship of
`terminal-unicode-core` plus VT-extension spec work (org repos updated
April 2026). Reliability is mixed — jeffquast's 2025 survey hit DEC
mode-query and config bugs (since fixed)
([survey](https://www.jeffquast.com/post/state-of-terminal-emulation-2025/)).
Small community, but its modal input + daemon/attach + standards work
are three blind-spot donors in one product.

### Hyper

The cautionary tale: 44.7k stars, MIT, Vercel-branded, and effectively
dormant — a "Future of Hyper" thread ([issue
#5435](https://github.com/vercel/hyper/issues/5435)) and an unanswered
"Is Hyper still developed?" issue from Oct 2024; 944 open issues;
no meaningful releases in the current cycle
([repo](https://github.com/vercel/hyper)). Its npm plugin/theme
ecosystem and JS config proved huge appetite for extensibility, but
Electron performance and corporate-owner indifference hollowed it out.
Lessons: star counts are a lagging, lying momentum signal (weight
release cadence and maintainer responsiveness instead), and an
extensibility story without an owner is a liability. Avoid; nothing to
adopt.

### Termius

Commercial, closed-source, subscription SSH client (Windows, macOS,
Linux, iOS, Android). Current differentiators: encrypted vault syncing
hosts/keys/snippets across devices including mobile, team sharing,
SFTP, real-time session sharing/takeover, built-in AI autocomplete
(describe intent, get a command inline — no API key), and **Windows
Hello biometric auth** ([termius.com](https://termius.com/index.html),
[changelog](https://docs.termius.com/changelog), [2026 review](https://www.virtualizationhowto.com/2026/05/i-tried-termius-for-my-home-lab-and-replaced-my-ssh-client/)).
Not a rival for the local PowerShell/WSL benchmark user, but it defines
expectations for the SSH slice of that user's week: identity, sync, and
cross-device continuity are product surfaces, not config files.
Blind-spot donations: Windows Hello, encrypted settings sync, mobile
companion.

### mintty / WSLtty

The stealth incumbent: mintty is Git for Windows' Git Bash terminal, so
its install base dwarfs most of this list. Still actively maintained by
one author — 3.8.2 stable 2026-02-15, further release 2026-06, Unicode
17.0, emoji rendering on by default, a text-to-speech output config
example, OSC 7 localhost paths
([changelog](https://github.com/mintty/mintty/wiki/Changelog),
[releases](https://github.com/mintty/mintty/releases)). Deep xterm
compatibility and Sixel, but it predates ConPTY: its Cygwin/MSYS2 pty
means native Windows console programs historically need winpty
shimming — the classic interop complaint winghostty's ConPTY path
simply doesn't have. WSLtty repackages mintty as a WSL front end and
tracks mintty releases
([wsltty](https://github.com/mintty/wsltty/releases)). Lessons: Unicode
/emoji currency as a maintenance cadence, and a marketing fact — most
Git Bash users have never chosen a terminal; they are winnable.

### Extraterm

One-developer project (sedwards2009), migrated off Electron to Qt;
pre-1.0 but steadily released — v0.80 (2025-01) added the **Scroll
Map** scrollback minimap, v0.82.0 shipped 2026-05-10
([news](https://extraterm.org/news.html)). Its enduring contribution is
shell-integration **command framing**: each command's output becomes a
frame you can collapse, delete, download, or pipe back in as input via
a `from` command — block-structured scrollback with zero AI. Windows
support covers CMD/PowerShell/WSL. Performance is its weakness:
jeffquast's 2025 conformance run flagged it (with iTerm2) as slow and
CPU-hungry
([survey](https://www.jeffquast.com/post/state-of-terminal-emulation-2025/)).
Adopt the ideas (framing, minimap), not the architecture.

### kitty via WSL

kitty still refuses a native Windows build; Linux/macOS/BSD only, so
Windows users run it under WSLg
([comparison coverage](https://www.saashub.com/compare-kitty-vs-windows-subsystem-for-linux-wsl)).
Two consequences matter. First, **protocol gravity**: kitty's keyboard
protocol is now table stakes — Windows Terminal Preview 1.25 adopted it
([4sysops](https://4sysops.com/archives/windows-terminal-preview-125-kitty-protocol-settings-search-and-gui-for-key-bindings/));
winghostty inherits kitty graphics and keyboard support via the Ghostty
core, but must track the moving target (kitten ssh, remote-control API,
OSC 99 notifications). Second, **WSLg is a distribution channel for
rivals**: a Windows 11 dev can run kitty, or any Linux terminal, with
no port. jeffquast's 2025 survey crowns kitty and Ghostty the Unicode
correctness champions — winghostty should loudly inherit that mantle on
Windows.

### MobaXterm

Commercial freemium (closed-source), the entrenched sysadmin terminal:
enhanced SSH client + built-in X server + Unix tools + SFTP browser in
one **portable single-exe**. Active through 2026: v26.1 (2026-03-06)
session-state indicators; v26.4 (2026-06-11) **smart-card SSH auth via
Microsoft CryptoAPI** and one-click SFTP from an SSH session; FIDO2
keys in the 2025–26 cycle
([download](https://mobaxterm.mobatek.net/download-home-edition.html),
[preview](https://mobaxterm.mobatek.net/preview.html)). Dated UI, but
it owns the enterprise remote-ops niche (PuTTY remains the legacy
fallback in the same category per 2026 roundups). Blind-spot donations:
enterprise auth (CryptoAPI smart cards, FIDO2) and portable-first
distribution as a first-class channel — winghostty's portable ZIP still
lacks updater apply (docs/status.md).

### yaw (new 2026 entrant)

A new free, open-source Electron terminal marketed hard at 2026
workflows: integrated text editor, SSH **and database** connection
manager (Postgres/MySQL/SQL Server/MongoDB/Redis), BYOK AI across nine
providers with auto-detection of AI CLIs, Tailscale integration,
no-signup/no-telemetry stance
([yaw's own roundup](https://yaw.sh/blog/best-terminal-emulators-windows-2026/)
— note the source is self-interested; independent coverage is thin, so
treat capability claims as unverified). Its existence is the datapoint:
new entrants now bundle infrastructure clients and AI by default. Same
Electron memory caveat as Wave. Watch, don't chase.

### ghostty-windows community fork family

The find of the sweep: multiple native Windows ports of Ghostty exist
besides winghostty. The root is adilahmeddev's `windows-apprt` fork
(~34,337 lines of Windows-specific code: Win32 runtime, DirectWrite
fonts, **D3D11-primary renderer with OpenGL fallback**, GDI chrome), on
which Thr45hx published an Inno-Setup-installed build documented as
"stable for daily use" as of 2026-03-14/15
([build log](https://github.com/Thr45hx/ghostty-windows/blob/master/BUILD-LOG.md)),
with gaps in IME cursor positioning, IPC, and installer signing. Around
it orbit near-identical repos (InsipidPoint/shiweis, WolftacDigital,
fl0under/cmux-windows, liamsmith86) claiming OpenGL 4.6/WGL, ConPTY,
tabs/splits, command palette, 66/66 action coverage and PowerShell-
automation tests
([example README](https://github.com/InsipidPoint/ghostty-windows/blob/main/README.md)).
**Uncertainty:** several appear to be mirrors or possibly AI-generated
clones of one another; stars, real activity, and code quality are
unverified. Strategically this is winghostty's exact niche contested:
users can't distinguish forks, upstream could bless one, and none ship
signed winget/Scoop packaging — winghostty's Authenticode + package-id
story is currently its clearest edge over them. Promote to a deep dive.

## Lessons for winghostty

### Does well (adopt candidates)

- **Quake-mode global hotkey** (Wave v0.14.5; Fluent had it in 2019) —
  no equivalent surface in docs/status.md.
- **Durable/attachable sessions** that keep contents and processes
  alive (Contour daemon+attach; Wave durable SSH) vs. winghostty's
  layout-only restore.
- **Command-output framing / block scrollback without AI** and a
  **scrollback minimap** (Extraterm).
- **Modal vi-like input mode** for keyboard selection/navigation
  (Contour) — pure keyboard-first territory.
- **Explorer context-menu integration** (Fluent) — absent from
  winghostty's documented Windows integration.
- **Unicode/emoji currency cadence** (mintty on Unicode 17.0 with
  emoji default within months).
- **Enterprise auth**: Windows Hello (Termius), CryptoAPI smart cards
  and FIDO2 (MobaXterm) for SSH flows.
- **Portable-first distribution with working portable update**
  (MobaXterm single exe) — winghostty's portable-ZIP apply is still
  unimplemented.
- **VT-standards participation** (Contour's unicode-core and VT
  extension specs) as a credibility channel.

### Does badly (avoid / exploit)

- **Electron cost is the category's open wound** — Wave at 400–800 MB
  with resize jank, Hyper, yaw. Winghostty's native Zig/Win32 fluidity
  is the exploit; publish comparative footprint/latency numbers.
- **Stars without stewardship** (Hyper: 44.7k stars, dormant) —
  momentum signals to weight are cadence and responsiveness; keep
  winghostty's release/issue hygiene visible.
- **Platform-framework bets die** (Fluent's UWP) — validates raw Win32;
  never couple core UX to a fashionable Windows UI layer.
- **Chrome-only differentiation loses to the platform vendor**
  (Fluent vs. Windows Terminal) — depth (VT correctness, fluidity,
  sessions) is the only defensible ground, exactly PRODUCT.md's line.
- **Thin AI wrappers add no moat** (Wave's "good but generic" AI) —
  do not bolt on AI to check a box.
- **x64-only Windows builds** (Wave) — winghostty's ARM64 support is a
  concrete differentiator worth advertising.
- **Legacy pty interop pain** (mintty's Cygwin pty vs. native console
  apps) — position winghostty as the upgrade for Git Bash users who
  never chose their terminal.
- **Unsigned fork builds** (ghostty-windows swarm) — exploit trust:
  signed installers, winget/Scoop, checksummed releases, and a clear
  "why this fork" identity page.

### Blind-spot candidates

See list (a) at top; headline items: durable/detachable sessions,
fork-swarm namespace risk, non-AI block scrollback, modal input,
enterprise auth, cross-device sync, scroll minimap, VT-standards
participation, quake mode, WSLg-delivered rivals, TTS-style
accessibility experiments.
