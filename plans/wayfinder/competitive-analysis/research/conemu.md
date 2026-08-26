# ConEmu + Cmder — deep dive

Executive summary (five lines):
ConEmu is the pre-ConPTY Windows power terminal (first release 2007, Far Manager companion) that faked a modern terminal on top of hidden conhost buffers via aggressive Win32 API hooking, and in doing so shipped a decade of Windows affordances — quake mode, elevated tabs, task/layout system, jump lists, default-terminal capture, GUI-apps-in-tabs — that newer terminals still haven't matched. Its architecture (ConEmuHk DLL injection, GDI rendering, ANSI emulation limited to the visible area) became its ceiling: antivirus false positives, injection conflicts, and no GPU path. Cmder wrapped ConEmu in an opinionated portable distribution (clink, git-aware prompt, Monokai) and out-starred it 27k to 9.2k, proving packaging beats engine. Both are now in maintenance twilight: ConEmu's last stable release is v23.07.24 (July 2023) with sporadic commits into April 2025 and ~1.1k open issues; Cmder's last release is May 2024 and its README now documents running *inside* Windows Terminal. The lesson set: invent OS-integration primitives (ConEmu's OSC 9;4 taskbar progress is now an industry standard adopted by Windows Terminal and Ghostty), but a solo maintainer, a settings dialog with hundreds of checkboxes, and an unfixable architecture will bleed even the most loyal user base.

## 1. Identity & strategy

- **What**: "Console Emulator" — a tabbed GUI presenter for Windows console applications, not a terminal emulator in the Unix sense. It runs real hidden conhost consoles and paints their buffers into its own window, layering tabs, splits, quake mode, and hotkeys on top ([repo](https://github.com/ConEmu/ConEmu), [Terminal vs Shell doc](https://conemu.github.io/en/TerminalVsShell.html)). Explicit self-description: host "any console application developed either for WinAPI (cmd, powershell, far) or Unix PTY (cygwin, msys, wsl bash)" ([conemu.github.io](https://conemu.github.io/)).
- **Lineage**: created by Zoin 2006–2008 as a Far Manager companion; developed by Maximus5 2009–2017 ([Wikipedia](https://en.wikipedia.org/wiki/ConEmu)). Repo now lives under the `ConEmu` org (Maximus5/ConEmu redirects there).
- **Target user**: exactly noctty's benchmark user, a decade earlier — Windows developers wanting tabs/splits/hotkeys over cmd, PowerShell, Far, cygwin/msys/WSL.
- **Governance/bus factor**: effectively bus factor 1 (Maximus5), donation-funded. Wikipedia's developer timeline ends 2017; releases continued sporadically to 2023, then stopped; a burst of third-party commits (asuiu, LeoMash, krobelus) landed April 2025 without a release ([commits](https://github.com/Maximus5/ConEmu/commits/master)).
- **License**: BSD-3-Clause. ~9.2k stars, 618 forks, ~1.1k open issues ([repo](https://github.com/ConEmu/ConEmu)).
- **Cmder** ([cmderdev/cmder](https://github.com/cmderdev/cmder)): MIT, ~27k stars — a *distribution*: ConEmu + clink (GNU Readline for cmd.exe) + clink-completions + git-aware prompt + Monokai + portable self-contained layout, "created out of pure frustration over absence of usable console emulator on Windows." Strategy today is survival-by-decoupling: README documents using Cmder's shell environment inside Windows Terminal and VS Code.

## 2. Performance & fluidity

- **Rendering**: CPU-side GDI text drawing; no GPU pipeline of any kind. High-DPI + ClearType GDI rendering is a documented performance sink (e.g., [FiraCode #420](https://github.com/tonsky/FiraCode/issues/420)); comparison sites consistently score Windows Terminal's GPU rendering above ConEmu for scroll/large-output smoothness ([Slant comparison](https://www.slant.co/versus/5489/34392/~conemu_vs_windows-terminal)).
- **Damage model**: polls/synchronizes hidden console buffers into its GUI — an extra copy step that a direct VT-parsing terminal doesn't pay. No published latency/throughput benchmarks from the project; Chad Austin's 2024 Windows terminal-latency benchmark did not even include ConEmu ([chadaustin.me](https://chadaustin.me/2024/02/windows-terminal-latency/)) — a visibility signal in itself.
- **Startup**: bare ConEmu is reputed fast ("opens quickly", [Slant](https://www.slant.co/versus/5489/34392/~conemu_vs_windows-terminal)); Cmder is notorious for 5s+ startups caused by clink + init.bat layering ([cmder #1211](https://github.com/cmderdev/cmder/issues/1211), [#2023](https://github.com/cmderdev/cmder/issues/2023), [#1122](https://github.com/cmderdev/cmder/issues/1122)).
- **Process-spawn tax**: ConEmuHk injection adds "small lag when new process is created," admitted in docs ([ConEmuHk](https://conemu.github.io/en/ConEmuHk.html)).
- **Animation**: quake-mode slide animation with 0–2000 ms configurable duration — deliberate, state-meaningful animation from 2010s-era GDI ([SettingsQuake](https://conemu.github.io/en/SettingsQuake.html)).

## 3. Native Windows integration (the crown jewels)

This is the decade of affordances the dive focus asks about:

- **Elevated tabs in one window**: `-new_console:a` runs a tab elevated via the RunAs verb; `:u` runs as another user, `:r` as restricted user — mixed-integrity tabs in a single window, with per-tab credentials ([NewConsole switches](https://conemu.github.io/en/NewConsole.html)). No modern terminal (incl. Windows Terminal, which refuses mixed elevation in one window) has fully matched this.
- **Default terminal capture (pre-Win11)**: ConEmuHk injected into explorer.exe, taskmgr.exe, devenv.exe etc. intercepts CreateProcess of console apps and re-parents them into ConEmu tabs — the "Default Terminal" feature years before Windows 11's official setting; limits: cannot hook elevated parents, requires ConEmu running first, trips antivirus ([DefaultTerminal](https://conemu.github.io/en/DefaultTerminal.html)).
- **Taskbar**: jump lists auto-populated from user Tasks (per-task checkbox) ([SettingsTaskBar](https://conemu.github.io/en/SettingsTaskBar.html)); taskbar progress via its own invention **OSC 9;4**, plus OSC 9;9 (cwd report) and 9;12 (prompt mark) ([AnsiEscapeCodes](https://conemu.github.io/en/AnsiEscapeCodes.html)). OSC 9;4 was adopted verbatim by Windows Terminal ([microsoft/terminal PR #8055](https://github.com/microsoft/terminal/pull/8055), [MS docs](https://learn.microsoft.com/en-us/windows/terminal/tutorials/progress-bar-sequences)) and has since spread to Ghostty, VTE, cargo, systemd ([survey](https://rockorager.dev/misc/osc-9-4-progress-bars/)).
- **Window docking/embedding**: "Inside" mode embeds ConEmu as a child pane *inside Windows Explorer* (context-menu "ConEmu Inside") or any HWND via `-insidewnd 0xHWND` ([InsideParent](https://conemu.github.io/en/InsideParent.html)); plus always-on-top, desktop-pinned, and quake window modes.
- **GUI apps as tabs (ChildGui)**: PuTTY, mintty, Notepad, GVim run as tabs/splits, caption stripped, Win+Z focus switch — ConEmu as a generic tool-window manager ([ChildGui](https://conemu.github.io/en/ChildGui.html)).
- **Explorer integration**: "ConEmu Here"/"Cmder Here" context menus (Cmder README).
- **WSL/cygwin/msys**: shipped a cygwin/msys "connector" + Ryan Prichard's wslbridge since build 170730 to provide a real POSIX pty with xterm emulation for WSL — pre-ConPTY engineering to get proper TUI behavior ([CygwinMsysConnector](https://conemu.github.io/en/CygwinMsysConnector.html), [wsl doc](https://conemu.github.io/en/wsl.html)).
- **ConPTY**: no evidence ConEmu ever moved its core onto ConPTY; the hidden-console + hooks + connector architecture remained (Cmder users asked in 2018, [cmder #1896](https://github.com/cmderdev/cmder/issues/1896)). *Uncertain: scattered ConPTY experiments may exist in dailies; none advertised.*
- **ARM64**: builds target x86/x64 only (README: "Windows XP+ 32-bit, Vista+ 64-bit"); no native ARM64 artifact found. *Marked uncertain but very likely absent.*
- **UAC/AV friction**: recurring Defender/ClamAV false positives on ConEmu binaries and ConEmuHk.dll, bad enough for a dedicated ["False Alarms" page](https://conemu.github.io/en/FalseAlarms.html) ([#1386](https://github.com/ConEmu/ConEmu/issues/1386), [#2476](https://github.com/ConEmu/ConEmu/issues/2476)).

## 4. Terminal capability

- **ANSI**: X3.64 + xterm 256-color + 24-bit truecolor ("TrueMod") since 2012 — years before conhost. Hard limits: escape sequences address the *visible working area only*; scrollback is not addressable; 256-color doesn't affect the scrollback buffer ([AnsiEscapeCodes](https://conemu.github.io/en/AnsiEscapeCodes.html)). It emulates a terminal on top of a console buffer, not a real VT screen model.
- **OSC surface**: titles, its own 9;x family (progress/cwd/prompt-mark). No OSC 8 hyperlinks, no OSC 52 clipboard, no Kitty graphics/sixel/iTerm2 images found in docs.
- **Keyboard**: recent 2025 commits show CSI-u edge-case fixes and a "switch terminal input mode" hotkey ([commits](https://github.com/Maximus5/ConEmu/commits/master)), but there is no kitty-keyboard-protocol depth.
- **Mouse**: xterm mouse emulation for mc/WSL via connector ([wsl doc](https://conemu.github.io/en/wsl.html)).
- **Scrollback/search**: console-buffer-backed scrollback (`-new_console:h9999` sets lines), a Find dialog, ANSI logging per tab (`:L`). Nothing resembling Ghostty's page-list scrollback or prompt-jump navigation.
- **Shell integration**: OSC 9;9/9;12 give cwd + prompt-start, used by "restore tabs in last cwd" — primitive but present a decade before FTCS/OSC 133 became standard.

## 5. Workflow features

- **Tasks**: the signature system. A Task = named set of commands with per-task icon, startup dir, hotkey, and inline split layout (`-new_console:s25H` etc.), launchable from the new-tab menu, jump lists, or its hotkey; `{Far}`-style names usable from the command line ([Tasks](https://conemu.github.io/en/Tasks.html), [NewConsole](https://conemu.github.io/en/NewConsole.html)). This unifies noctty's separate "profile" and "session layout" concepts: one keystroke = a whole named multi-pane workspace.
- **Quake mode**: slide animation, auto-hide on focus loss, global summon hotkey, "restore to active monitor" (follows mouse across multi-monitor), always-on-top ([SettingsQuake](https://conemu.github.io/en/SettingsQuake.html)).
- **Session restore**: "Auto save/restore opened tabs" persists tabs/panes and last cwd (via OSC 9;9) across restarts ([SettingsStartup](https://conemu.github.io/en/SettingsStartup.html)) — but with chronic fidelity bugs: splits restored into the wrong tab ([#1892](https://github.com/ConEmu/ConEmu/issues/1892)), cwd wrong for non-cmd shells ([#784](https://github.com/ConEmu/ConEmu/issues/784)), restore silently failing ([#671](https://github.com/ConEmu/ConEmu/issues/671)).
- **Tabs/splits**: full tabs + arbitrary splits (Windows Terminal shipped without panes for years; Slant still contrasted this in ConEmu's favor).
- **Keybinding model**: large hotkey table plus user-definable "Key Macros" in the GuiMacro language; no command palette, no fuzzy anything.
- **No broadcast input** found in docs (*uncertain — grouped input exists via "Group keyboard input" in some builds; not load-bearing*).

## 6. Reliability & quality signals

- ~1.1k open issues against a near-dormant release train (last stable July 2023; commit bursts without releases through April 2025, including a startup double-free crash fix that has never shipped in a stable release) ([releases](https://github.com/Maximus5/ConEmu/releases), [commits](https://github.com/Maximus5/ConEmu/commits/master)).
- Dominant issue themes: injection conflicts (MacType, AnsiCon, Intel Pin, NVIDIA CoProcManager crashes — [ConEmuHk](https://conemu.github.io/en/ConEmuHk.html)), AV false positives, session-restore fidelity, DPI.
- Long-run user sentiment includes flat stability complaints: "It has never been stable for me, so I stick with the console" ([HN thread](https://news.ycombinator.com/item?id=12987355)).
- The July 2023 release existed to patch a title-report control-character injection vulnerability ([Whats_New](https://conemu.github.io/en/Whats_New.html)) — security-fix-only cadence is the signature of maintenance twilight.
- Cmder inherits all of this plus its own layer: its final release (v1.3.25, May 2024) shipped to fix "another dependency with a known vulnerability" ([releases](https://github.com/cmderdev/cmder/releases)).

## 7. Configuration & extensibility

- **Config model**: giant GUI settings dialog (dozens of pages, hundreds of options) backed by registry or portable ConEmu.xml. Docs admit "the option amount may overwhelm new users," mitigated by a first-run "Fast Configuration" dialog and Ctrl+F *search inside the settings dialog* ([SettingsFast](https://conemu.github.io/en/SettingsFast.html), [Settings](https://conemu.github.io/en/Settings.html)).
- **Scripting/automation**: **GuiMacro** — a remote-callable macro language (`ConEmuC -GuiMacro`) that any external script can use to drive tabs, splits, settings, and actions in a running instance ([GuiMacro](https://conemu.github.io/en/GuiMacro.html)). Deeper than noctty's allowlisted `+perform-action`.
- **Theming**: palettes per-tab (`-new_console:P:"<palette>"`), tab wallpapers, extensive appearance knobs. No plugin system.
- **Cmder's config layer**: `%CMDER_ROOT%` user profile scripts, aliases, portable git-for-windows — configuration-as-distribution.

## 8. Packaging & adoption

- ConEmu: installer + portable 7z/zip; winget `Maximus5.ConEmu` ([winget.run](https://winget.run/pkg/Maximus5/ConEmu)), Chocolatey `ConEmu` 23.7.24 ([chocolatey](https://community.chocolatey.org/packages/ConEmu)), Scoop. AppVeyor/Azure Pipelines CI with "daily" channel.
- Cmder: winget `Cmder.Cmder`/`CmderMini`, choco, scoop; portable zip is the identity ([wiki](https://github.com/cmderdev/cmder/wiki)).
- **Momentum asymmetry**: distribution (Cmder, ~27k stars) tripled the engine (ConEmu, ~9.2k) on the strength of defaults alone. Both curves are now flat; Cmder's own docs treat Windows Terminal as a host, not a rival.
- No code signing story surfaced for either; AV reputation problems suggest weak/no Authenticode reputation (*uncertain on current signing state*).

## 9. What users complain about

1. **Slow/dated rendering** vs GPU terminals; GDI + high DPI + ClearType degradation ([FiraCode #420](https://github.com/tonsky/FiraCode/issues/420), [Slant](https://www.slant.co/versus/5489/34392/~conemu_vs_windows-terminal)).
2. **AV false positives** on ConEmuHk/ConEmu binaries, repeatedly quarantining the app ([FalseAlarms](https://conemu.github.io/en/FalseAlarms.html), [#1386](https://github.com/ConEmu/ConEmu/issues/1386)).
3. **Injection fragility**: crashes from hook conflicts with other injectors and drivers ([ConEmuHk](https://conemu.github.io/en/ConEmuHk.html)); instability reports going back years ([HN](https://news.ycombinator.com/item?id=12987355)).
4. **Overwhelming settings** ("settings area is really overwhelming" — acknowledged on ConEmu's own [Reviews page](https://conemu.github.io/en/Reviews.html)).
5. **Session restore inaccuracy** (wrong cwd, splits collapsing to tab 1: [#784](https://github.com/ConEmu/ConEmu/issues/784), [#1892](https://github.com/ConEmu/ConEmu/issues/1892)).
6. **Cmder startup time** 5s+ ([#1211](https://github.com/cmderdev/cmder/issues/1211), [#2023](https://github.com/cmderdev/cmder/issues/2023)).
7. **Stalled maintenance**: unreleased fixes, 1.1k open issues, migration blog posts ("Windows Terminal as the best replacement for ConEmu", [pimpl.dev](https://pimpl.dev/posts/2023/03/windows-terminal-instead-of-conemu/)).

## 10. Lessons for noctty

### Does well (adopt-candidates)

1. **Elevated tabs**: `-new_console:a` admin-in-a-tab (plus run-as-user/restricted). noctty's status.md and capability matrix have *no elevation story at all* beyond "UAC may prompt" for updates. A per-tab/per-profile "run elevated" with clear visual marking is a decade-proven power feature.
2. **Quake mode**: global-summon dropdown with auto-hide, restore-to-active-monitor, and tuned slide animation ([SettingsQuake](https://conemu.github.io/en/SettingsQuake.html)). Absent from noctty; upstream Ghostty ships it on macOS/Linux, making the gap conspicuous.
3. **Tasks = profile + layout + hotkey in one object**: a named command set that materializes a full split layout on one keystroke and is addressable from CLI ([Tasks](https://conemu.github.io/en/Tasks.html)). noctty has profiles and session restore but no "named workspace layout" primitive.
4. **Taskbar jump lists populated from profiles/tasks** ([SettingsTaskBar](https://conemu.github.io/en/SettingsTaskBar.html)) and **OSC 9;4 → ITaskbarList3 progress**. ConEmu invented 9;4 and the ecosystem (cargo, systemd, WT, Ghostty) now emits it; noctty's docs never mention taskbar progress or jump lists — cheap, deeply native wins.
5. **Windows 11 default-terminal registration**: ConEmu burned enormous effort faking this with injection; the OS now offers a sanctioned hook. noctty's matrix is silent on it. Registering as a default terminal host would capture the exact workflow (consoles spawned by IDEs/Explorer) that kept ConEmu users loyal.
6. **Cmder's distribution lesson**: opinionated batteries-included defaults (prompt, git integration, portable layout) tripled the audience of the underlying engine. A noctty portable ZIP with polished PowerShell/WSL defaults is a distribution multiplier, not a feature.
7. **Settings search**: Ctrl+F inside the settings dialog jumps to and highlights the matching control — worth mirroring in noctty's native settings/universal palette.

### Does badly (avoid / exploit)

1. **DLL injection as platform strategy**: ConEmuHk bought features but cost AV quarantines, injector conflicts, per-spawn latency, and crashes ([ConEmuHk](https://conemu.github.io/en/ConEmuHk.html), [FalseAlarms](https://conemu.github.io/en/FalseAlarms.html)). noctty should exploit this: everything ConEmu hooked for is now achievable via ConPTY + documented APIs — say so in positioning.
2. **Emulation-on-top-of-console-buffer**: ANSI limited to the visible area, unaddressable scrollback, no modern OSC surface — a ceiling noctty's real VT core clears by construction. Differentiator to advertise, not just possess.
3. **Configuration sprawl**: hundreds of GUI checkboxes needing a "Fast Configuration" rescue dialog. Matches PRODUCT.md's anti-reference ("feature-count competition"); keep the settings surface curated.
4. **Bus factor 1 + silent release stall**: fixes sitting unreleased on master since April 2025 while the last stable is 2023 — loyal users drift when cadence dies. noctty (also single-maintainer) should treat visible release cadence and a "what's shipped vs merged" signal as retention features.
5. **Approximate session restore**: restoring tabs into wrong directories or collapsing splits ([#784](https://github.com/ConEmu/ConEmu/issues/784), [#1892](https://github.com/ConEmu/ConEmu/issues/1892)) taught users to distrust the feature. noctty's exact-layout restore is a direct exploit — keep it provably exact.
6. **Cmder's heavy shell-side init** (clink + batch scripts → 5s startups): keep noctty shell integration injection-light and measured.

### Blind-spot candidates (no PRODUCT.md category)

1. **Elevation as a first-class UX dimension** — mixed-integrity tabs, elevation indicators, what restore does with elevated sessions. PRODUCT.md never mentions UAC/elevation.
2. **Being the terminal for *other* apps' consoles** — Windows 11 default-terminal host registration; the IDE/Explorer-spawned-console capture that was ConEmu's stickiest feature ([DefaultTerminal](https://conemu.github.io/en/DefaultTerminal.html)).
3. **Attach/adopt existing consoles and host GUI tools**: ChildGui (PuTTY/GVim/notepad as tabs) and attach-running-console made ConEmu a tool-window manager, not just a terminal ([ChildGui](https://conemu.github.io/en/ChildGui.html)). Even if declined, it deserves an explicit scope decision.
4. **Embeddability**: "Inside" mode (terminal as a child pane of Explorer or any HWND) ([InsideParent](https://conemu.github.io/en/InsideParent.html)) — the inverse of hosting; no noctty category for being embedded.
5. **OS-shell launch surfaces**: jump lists, Explorer "Open noctty here" context menu, per-task taskbar pinning — a "launch topology" category PRODUCT.md lacks.
6. **The environment-distribution layer**: Cmder shows a market for the terminal shipped *with* a curated shell environment, and for the environment being consumable from other terminals. noctty has no concept of a redistributable defaults bundle.
7. **Wire-protocol invention as moat**: ConEmu's OSC 9;4 outlived its own dominance ([adoption survey](https://rockorager.dev/misc/osc-9-4-progress-bars/)). A category for "sequences/protocols noctty could originate for Windows-native affordances" (e.g., elevation request, jump-list contribution) doesn't exist in PRODUCT.md.
