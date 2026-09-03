# Status

What works in noctty, what is experimental, and what is out of scope. When
this page disagrees with a commit message, trust this page.

Last updated: 2026-09-02, against current fork HEAD.

For a row-by-row mapping against official Ghostty docs, including the
implementation detail this page leaves out, see
[windows-capability-matrix.md](windows-capability-matrix.md). For Windows
paths, shells, updates, automation, and troubleshooting, see
[windows.md](windows.md).

## Upstream

noctty is based on post-`v1.3.1` upstream main (`1.3.2-dev`, `ba398dfff`,
2026-04-05). It is a hard fork with scheduled merge windows; see the
[upstream merge policy](upstream-merge-policy.md).

## Supported platform

- Windows 10 version 1809 (build 17763) or newer, and Windows 11, on
  x64 and ARM64. ConPTY is a static import, so earlier builds fail to load
  rather than degrade.
- No macOS, Linux, or cross-platform app runtime ships from this repo.
  `libghostty-vt` stays buildable for non-Windows targets as a library.
- WSL sessions work from the profile picker. Making WSL the default shell
  requires an explicit `command = wsl.exe`; [windows.md](windows.md#shells)
  explains why.

## What works today

### Terminal core (shared with upstream Ghostty)

- VT parsing, screen / scrollback / alt-screen, DEC and xterm behaviors.
- 256-color and true-color.
- Bracketed paste, mouse tracking, OSC 8 hyperlinks, OSC 10 / 11 / 52 (all
  OSC 52 selectors target the single native Windows clipboard).
- Bidi, combining marks, grapheme cluster rendering.
- Kitty graphics protocol and inline image display.
- Kitty keyboard protocol with press, repeat, and release events, Caps Lock
  and Num Lock state, and left/right modifier identity.
- Shell integration for bash, zsh, fish, elvish, nushell, PowerShell, and
  `cmd.exe` through automatic detection. Command Prompt gets prompt/cwd marks
  from `PROMPT`; an active Clink adds command-finish marks and exit codes when
  it loads the shipped script.
- Live config reload via keybind (`Ctrl+Shift+,`).
- `libghostty-vt` retained for Zig and C consumers.

Win32-validated VT protocol coverage is tracked in
[windows-vt-conformance.md](windows-vt-conformance.md).

### Windows application runtime (new in this fork)

- Packaged builds prefer the bundled side-by-side ConPTY and warn before
  falling back to the in-box conhost, which strips Kitty APC and Sixel DCS
  payloads. See
  [windows-vt-conformance.md](windows-vt-conformance.md#conpty-transport-generations-and-mangling-catalog).
- Native Win32 windows, tab bar with overflow, a numeric tab overview
  (`toggle_tab_overview`, no default keybind), same-window tab reorder, and
  exact-pane drag-to-split.
- Horizontal and vertical splits.
- Deliberate elevated windows through the command palette or
  `new_window_elevated:<profile-key>`, with integrity-scoped single-instance
  IPC and no elevated session restore. See [Running elevated](windows.md#running-elevated).
- Structural undo/redo for new splits, single-tab close (restoring the
  exact tab, panes, and layout), and drag-to-split subtree transfers. Tab
  reorder and multi-tab close modes are not undoable.
- Native right-click context menus.
- In-app profile picker for detected shells: PowerShell 7, Windows
  PowerShell, `cmd`, Git Bash, and WSL distributions when WSL responds.
- Concrete aliases from `%USERPROFILE%\.ssh\config` appear in the profile
  picker and universal palette and launch through the system `ssh.exe`.
- Native taskbar jump list with recent working directories and detected
  shell profiles.
- Classic Explorer `Open noctty here` verbs for folders, folder backgrounds,
  and drives, registered by the installer or explicitly per-user for
  portable builds.
- Per-monitor DPI scaling.
- DWM dark caption that follows the app theme on all supported builds, plus
  an integrated title bar with native caption actions and Snap Layout hover
  on Windows 11 while the tab bar and decorations are visible
  (`window-show-tab-bar = never` and older builds keep the stock caption).
- High-contrast mode detection and palette switching.
- IME for CJK and other composed input.
- A local sensitive-input indicator for no-echo input. `toggle_secure_input`
  is a visual affordance only; it does not block system-wide keyboard hooks
  the way macOS Secure Keyboard Entry does.
- Drag-and-drop of files, plain text, URLs, and HTML into a pane. Shift
  changes file/text handling, Ctrl suppresses file-path quoting, and Alt has
  no assigned behavior.
- Per-pane docked scrollback search (`Ctrl+Shift+F`) with regex, case, and
  whole-word modes, result navigation, and match markers on the scrollbar.
- Per-pane graphical scrollbars. `scrollbar = system` follows Windows'
  dynamic-scrollbar preference; `never` hides the widget without disabling
  scrolling.
- Clipboard paste confirmation for risky content, including dropped
  payloads, gated by `clipboard-paste-protection`. HTML copy writes both
  CF_HTML and a plain-text fallback. `clipboard-codepoint-map` applies to
  plain, VT, and HTML selection copies; clipboard reads, URL copies, OSC 52
  writes, and `write_screen_file` exports are not mapped.
- A configurable quick terminal on an edge or the center of the selected
  monitor. It has no default binding; `global:` keybinds use
  `RegisterHotKey`. `exclusive` keyboard interactivity falls back to focused
  input, and `quick-terminal-space-behavior` has no Windows effect.
- WinRT Action Center notifications with an in-app banner/log fallback,
  gated by `desktop-notifications`. Command-finish toasts also need
  `notify-on-command-finish` and a `notify` action, and are the only toasts
  that focus the originating pane when clicked; OSC 9 / OSC 777 toasts are
  display-only. Command-finish toasts depend on OSC 133 command marks, which
  `cmd.exe` does not supply.
- Taskbar progress for the active pane in each host window, driven by
  terminal progress reports when `progress-style` is enabled.
- Session restore via `window-save-state`: windows, tabs, splits, profiles,
  working directories, and explicit titles come back; child processes do
  not. The opt-in `window-save-state-scrollback` line count also restores
  bounded, clearly marked plain-text pane snapshots.
- Named layouts (C17): save the focused window's tabs, splits, profiles,
  working directories, and titles, then launch it in a new window from a
  keybind, the universal palette, or `+new-window --launch-layout=<name>`.
- Ctrl-based default keybindings, mostly shared with Ghostty's non-macOS
  defaults. Windows-specific exceptions include `Alt+Arrow` pane focus and
  `Alt+F4` to close the window.
- `key-remap` applies to focused and in-app keybinds and to terminal
  encoding, but not to `global:` hotkeys, which register the literal chord.
- Native settings window (Appearance, Terminal, Shell, Privacy, Updates,
  Keybindings, Advanced) that stages edits until Save and patches your
  config without rewriting unrelated text.
- Universal palette: actions, tabs, panes, profiles, named layouts, themes,
  native settings, help, and recent commands in one fuzzy-searched,
  keyboard-driven list.
- Local CLI automation with versioned JSON state and policy-bounded verbs
  for windows, tabs, splits, focus, actions, and control-free text; see
  [automation.md](automation.md).
- Quick select (`Ctrl+Shift+Space`) labels URL, path, git SHA, IP address,
  and UUID matches in the visible viewport for keyboard copy, allowed-scheme
  open, or protected paste.
- Copy mode (`Ctrl+Shift+X`): modal vi-style selection and scrollback
  navigation, with keyboard copy/cancel and no PTY input leakage.
- Opt-in Job Object limits for Windows-local child processes through the
  retained `linux-cgroup*` keys and `windows-job-object-kill-on-close`. Off
  by default; WSL process trees are not covered.

### Performance measurement

- A reproducible Windows benchmark suite covers headless VT throughput
  (`zig build bench:vt-throughput`) and interactive metrics against the real
  app (`test/windows/bench-windows.ps1`): cold start to first frame, frame
  time, memory per pane, idle CPU/GPU, and ConPTY round trip. CI gates the
  headless throughput floor; interactive thresholds are provisional and
  inactive.
- The quarantined historical same-machine baseline, methodology, proxies,
  and the camera/photodiode procedure for physical key-to-pixel latency are
  in [windows-benchmark-methodology.md](windows-benchmark-methodology.md).
  Cross-terminal comparisons are not published; competitor adapters report
  `not-supported` until they can prove the same causal endpoint.

### Renderer

- Terminal content renders with OpenGL 4.3+ via WGL.
- Window chrome uses a separate D3D11/DirectComposition + DirectWrite
  pipeline with GDI fallback; it never touches the terminal renderer.
- Presentation is power- and visibility-aware: focused non-saver cadence is
  unchanged, unfocused and saver pacing is capped, and minimized or
  DWM-cloaked windows stop presenting. Details and measurement fields are in
  [windows.md](windows.md#power-and-battery).

### Updater

- Checks the stable release feed (GitHub Releases by default, overridable
  with `auto-update-feed-url`) at most once every 24 hours and never replaces
  binaries silently.
- `auto-update = download` stages only releases whose checksum metadata and
  Authenticode signatures both verify. Portable ZIPs additionally require a
  publisher-signed manifest covering every payload file; releases without it
  stay on the release-page path. Installer-managed installs launch the verified
  installer; portable installs apply a verified ZIP on the next launch and roll
  back an unconfirmed or failed startup. Applying a staged update is always
  user-initiated. Details in [windows.md](windows.md#updates).

### Windows package managers

- WinGet package id: `AmanThanvi.noctty` (bootstrap pending).
- Scoop bucket: `https://github.com/amanthanvi/scoop-noctty`.

### Crash reports

- Crash dumps stay local under `%LOCALAPPDATA%\noctty\crash`. There is no
  automatic upload, and no code path to upload exists in this repo.
- `noctty +crash-report` reads whatever is there. Details in
  [windows.md](windows.md#crash-reports-and-diagnostics).
- Unreadable session state is quarantined, never deleted, and repeated
  startup failures fall back to safe mode. Details in
  [windows.md](windows.md#session-restore-and-recovery).
- `+diagnostic-bundle` exports are explicit and redact terminal content,
  environment, and config values by default.

## Experimental / partial

### Default-terminal handoff

`+register-default-terminal` and `+unregister-default-terminal` implement
per-user registration and exact selection restore, using Windows Terminal
1.24 or newer OpenConsole for console delegation. A delegated console
application is adopted into a visible noctty window, verified live on
Windows 11 26200. Still missing: noctty cannot appear in the Windows Settings
picker without package identity, and it implements no `IConsoleHandoff`, so
Windows Terminal must stay selected as the console half. Details in
[windows.md](windows.md#default-terminal).

### Windows UI Automation (accessibility)

Covered: tabs expose TabItem with selection state; the new-tab and overflow
buttons have real names instead of their painted glyphs; the docked-search
toggles expose Toggle state; the search result count and host banners are
live regions; the terminal scrollbar exposes RangeValue; and the command
palette and settings sections expose list and selection semantics. Terminal
text is exposed through TextPattern/TextPattern2 with bounded ranges (up to
500 history rows within a 40,000-cell budget, plus the live viewport),
visible geometry, an accurate caret while the live screen remains inside
that bounded snapshot, and real selections. In deeper scrollback the
viewport remains available, but the off-window live caret is reported at
the document end.

Not yet covered: custom-painted caption buttons, the profile picker and
tab-overview overlay rows, context menus, toasts, and quick-terminal chrome.
There is no keyboard focus-region cycle, so chrome cannot be reached from the
terminal without a mouse.

No screen reader has been measured against a release yet. NVDA was measured
against a pre-release branch build, with mixed results: terminal text,
scrollbar, live regions, and banners read correctly; tab items, the search
flag toggles, and the docked search query edit do not announce their role,
state, or name. Per-widget expectations, what the automated UIA harness
proves, and per-reader results are in
[accessibility-matrix.md](accessibility-matrix.md).

### Link previews

`link-previews` is parsed and the shared core emits link-hover preview
actions, but the Win32 runtime does not render the preview tooltip. Link
matching, hover highlighting, and opening work.

### Status bar

Not shipping. `Host.statusBarHeight()` returns 0, so no terminal rows are
reserved; host banners and overlays carry transient status instead.

### Win32 runtime extraction

The Win32 runtime is still centered on one large file
(`src/apprt/win32.zig`). Extraction into focused modules is in progress and
lands incrementally.

## Known caveats

- Installers and the Windows binaries inside the portable ZIP are
  Authenticode-signed; the ZIP container itself is checksummed, not signed.
  SmartScreen can still warn for a new or low-reputation publisher
  certificate; see
  [getting-started.md](getting-started.md#about-the-smartscreen-warning).
- GitHub Issues are for reproducible bugs. For questions, feature
  discussion, and feedback, use
  [Discussions](https://github.com/amanthanvi/noctty/discussions).
- OpenGL 4.3 through WGL is a hard floor with no software fallback renderer.
  Below it, noctty shows a startup diagnostic with the detected version and
  does not start; see [windows.md](windows.md#gpu-floor-and-opengl-driver-issues).
- No supported Linux application packaging. Upstream's Flatpak and Snap
  surfaces are removed; the curated Nix flake supports only `libghostty-vt`.
- A few generated artifacts still reference upstream: the `libghostty-vt`
  pkg-config `URL` field, the vim syntax-file headers, and a link in the
  generated bash completions point at `ghostty-org/ghostty`.
- Crash capture is local-only, and some hard-abort paths may still
  terminate before Windows can produce a dump.
- Power- and visibility-aware render pacing has not been exercised on a
  machine with a battery, and the DWM cloak/uncloak WinEvent path has not
  been observed across a real virtual-desktop switch. Both are argued from
  the documented Win32 contracts and covered by unit tests over the pure
  policy and event-filter functions only.

## Out of scope

- macOS application packaging and Xcode workflows.
- GTK / Linux / Wayland / X11 app-runtime work.
- Flatpak, Snap, or other Linux desktop packaging.
- Replicating upstream's community process or governance.

## What's next

No formal roadmap. Likely next areas:

- Narrator and JAWS results for the
  [screen-reader matrix](accessibility-matrix.md), NVDA at 100/200/300%
  scaling and with High Contrast on, the fixes for the NVDA failures
  already recorded there, and UI Automation for caption buttons, overlay
  rows, and menus.
- A keyboard focus-region cycle so window chrome is reachable without a
  mouse.
- Continuing the `src/apprt/win32.zig` extraction.
- Broader local crash metadata and report packaging.
- ARB-context OpenGL migration paired with atlas rebuild.

Contributions that advance any of the above are welcome.
