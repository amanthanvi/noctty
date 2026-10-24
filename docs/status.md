# Status

What works in noctty, what is experimental, and what is out of scope. When
this page disagrees with a commit message, trust this page.

Last updated: 2026-10-16, against fork `main` at `f41abb9a9`.

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
  rather than degrade. The default OpenGL renderer on a Snapdragon PC
  additionally needs the Microsoft Store "OpenCL, OpenGL, and Vulkan
  Compatibility Pack", because Qualcomm ships no desktop OpenGL driver;
  without it noctty falls back to the D3D11 renderer (beta), which is included
  in the ARM64 build and does not need it for text. See
  [windows.md](windows.md#windows-on-arm-without-a-vendor-opengl-driver-needs-the-compatibility-pack).
- Windows 10 is a supported floor, not a tested target. CI runs on Windows
  Server 2025 (`windows-2025`, `windows-latest`) and Windows 11 ARM64
  (`windows-11-arm`), and the one interactive job is a self-hosted Windows 11
  machine that runs only on request. GitHub offers no Windows 10 image. A
  weekly, non-required job on Windows Server 2022 (build 20348) runs the unit
  suite and a hidden-desktop launch below build 22000, which exercises the
  startup-time Windows 10 branches; unit tests also stand in for older builds.
  A person runs the
  [Windows 10 release checklist](windows10-release-checklist.md) on a Windows 10
  22H2 machine before a release. Chrome, input and startup changes are
  unmeasured on Windows 10 unless a page says otherwise.
  [windows.md](windows.md#windows-tabs-and-splits) describes the
  frameless undecorated window on Windows 10, which was exercised only by
  forcing that code path on Windows 11.
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
- Kitty graphics protocol and inline image display. Sixel is passed through
  by the bundled ConPTY but not decoded or drawn; see
  [inline graphics](windows.md#inline-graphics-replies-sixel-and-memory).
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

- Packaged and source builds carry the bundled side-by-side ConPTY. If noctty
  falls back to the in-box conhost, which strips Kitty APC and Sixel DCS
  payloads and returns no colour-query replies, it shows a banner naming the
  reason. See
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
  reorder and multi-tab close modes are not undoable. `clear_screen` and
  `reset` have a terminal-local undo and redo that restores the saved
  screen; with the bundled ConPTY the restored content is shifted to the
  console's live cursor, and some cases can still leave noctty and ConPTY
  out of step (see [Known caveats](#known-caveats)).
- Native right-click context menus.
- A close X on every tab, the only tab of a window included (an undecorated
  window has no caption buttons). The X of a window's only tab closes the
  window, as its own close button does, asking first when a process would
  be lost. `close_tab:this` (Ctrl+Shift+W) still keeps the tab for undo.
- In-app profile picker for detected shells: PowerShell 7, Windows
  PowerShell, `cmd`, Git Bash, and WSL distributions when WSL responds.
- Concrete aliases from `%USERPROFILE%\.ssh\config` appear in the profile
  picker and universal palette and launch through the system `ssh.exe`.
- Native taskbar jump list with recent working directories and detected
  shell profiles. From 1.3.133 a portable copy builds none, so it leaves the
  installed app's list alone; earlier portable copies replaced it at every
  start.
- Classic Explorer `Open noctty here` verbs for folders, folder backgrounds,
  and drives, registered by the installer or explicitly per-user for
  portable builds.
- Per-monitor DPI scaling. With `window-width` and `window-height` set, a
  window moved to a monitor of another DPI takes the size it opens at there,
  and its frame is laid out at the new DPI (measured with the D3D11 renderer
  on one two-monitor machine; see [Known caveats](#known-caveats) for the one
  gap).
- DWM dark caption that follows the app theme on all supported builds, plus
  an integrated title bar with native caption actions and Snap Layout hover
  on Windows 11 while the tab bar and decorations are visible
  (`window-show-tab-bar = never` and older builds keep the stock caption).
  On Windows 11, `window-decoration = none` keeps the system frame with no
  caption (resize edges, shadow, Alt+Space menu), and while the tab bar is
  shown the window can be dragged by its tab strip. Right-clicking that strip
  or the integrated title bar's empty caption opens the window menu. The
  drag, the double-click maximize and the right-click menu were checked with
  real mouse input on Windows 11 build 26300 (a right-click on an active
  window opened no menu until that check found why); Snap was not measured.
- The tab strip follows the Windows accent colour by default
  (`accent-follow-system`); the rest of the chrome keeps its fixed palette.
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
  dynamic-scrollbar preference: with dynamic scrollbars on, the bar starts
  fading 1.5 s after the last activity (hovering or dragging holds it) and
  its window is hidden once it has faded; scrolling, output that moves the
  viewport, or the pointer reaching the pane's right edge bring it back, and
  UI Automation reports it offscreen while it is hidden. `never` hides the
  widget without disabling scrolling.
- Clipboard paste confirmation for risky content, including dropped
  payloads, gated by `clipboard-paste-protection`. HTML copy writes both
  CF_HTML and a plain-text fallback. `clipboard-codepoint-map` applies to
  plain, VT, and HTML selection copies; clipboard reads, URL copies, OSC 52
  writes, and `write_screen_file` exports are not mapped. A program's OSC 52
  read (`clipboard-read = ask` by default) or write (when
  `clipboard-write = ask`) raises its own prompt that names the tab; Allow
  only works half a second after the prompt opens and after the last key
  press. Cancel or Escape on a read prompt answers the program with an
  empty reply at once.
- A configurable quick terminal on an edge or the center of the selected
  monitor. It has no default binding; `global:` keybinds use
  `RegisterHotKey`. `exclusive` keyboard interactivity falls back to focused
  input, and `quick-terminal-space-behavior` has no Windows effect.
- WinRT Action Center notifications with an in-app banner/log fallback,
  gated by `desktop-notifications`. Command-finish toasts also need
  `notify-on-command-finish` and a `notify` action. Every toast from a
  terminal pane (OSC 9, OSC 777, command finished, program status
  ([OSC 7501](windows.md#program-status-osc-7501)) and the "Copied ... to
  clipboard" notices) names its tab and focuses its pane when its popup is
  clicked, and in an installed copy when its Action Center entry is
  clicked (COM toast activator; not yet exercised on a real desktop).
  A pane keeps one toast in Action Center, removed when its tab is seen,
  when the pane or tab closes, and at exit.
  Command-finish toasts depend on OSC 133 command marks, which plain
  `cmd.exe` does not supply (Clink with the shipped script does).
- Taskbar progress for the active pane in each host window, driven by
  terminal progress reports when `progress-style` is enabled.
- Program status ([OSC 7501](windows.md#program-status-osc-7501)): a program
  reports idle, working, done, blocked or failed, and tabs show a badge, the
  taskbar shows progress, and `goto_attention` (no default key) jumps to the
  most urgent other tab.
- Session restore via `window-save-state`: windows, tabs, splits, profiles,
  working directories, and explicit titles come back; child processes do
  not. The opt-in `window-save-state-scrollback` line count also restores
  bounded, clearly marked plain-text pane snapshots. The next launch restores
  what was open when the session ended: what the last window held when it
  went, however it went (its close, its last tab or pane, its last shell
  exiting), or every window a quit closed. Undo history is not saved. Only
  one noctty process
  owns `session-state.json`; a second instance, a forwarded launch, `-e` and
  `--working-directory` launches neither restore nor save it.
- Named layouts (C17): save the focused window's tabs, splits, profiles,
  working directories, and titles, then launch it in a new window from a
  keybind, the universal palette, or `+new-window --launch-layout=<name>`.
- Ctrl-based default keybindings, mostly shared with Ghostty's non-macOS
  defaults. Windows-specific exceptions include `Alt+Arrow` pane focus,
  `Alt+F4` to close the window, `F11` for fullscreen, `Ctrl+Shift+Z` and
  `Ctrl+Shift+Y` for undo and redo, and `Ctrl+F6` for the focus-region cycle
  (a bare `F6` and `Ctrl+Enter` go to the program).
- `key-remap` applies to focused and in-app keybinds and to terminal
  encoding, but not to `global:` hotkeys, which register the literal chord.
- Native settings window (Appearance, Terminal, Shell, Privacy, Updates,
  Keybindings, Advanced) that stages edits until Save or Discard changes
  (Discard first asks, naming how many fields would be lost) and patches
  your config without rewriting unrelated text. Its "Open in default
  editor" button and `+edit-config` without `VISUAL`/`EDITOR` open the config
  through the `.txt` association rather than the file's own (Settings still
  refuses an executable-type extension). A "Config
  problems" list (palette row, Settings > Advanced) shows what noctty could
  not use from the config file.
- Universal palette: actions, tabs, panes, profiles, named layouts, themes,
  native settings, help, and recent commands in one fuzzy-searched,
  keyboard-driven list.
- Local CLI automation with versioned JSON state and policy-bounded verbs
  for windows, tabs, splits, focus, actions, and control-free text; see
  [automation.md](automation.md).
- Quick select (`Ctrl+Shift+Space`) labels URL, path, git SHA, IP address,
  and UUID matches in the visible viewport for keyboard copy, allowed-scheme
  or local-path open, or protected paste. Paths include drive, `.\` and `..\`
  forms with an optional `:line:col` or `(line,col)` suffix, which is
  recognized but does not open the file at that line; UNC shares are recognized, copied and never
  opened.
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

- Terminal content renders with OpenGL 4.3+ via WGL by default. A
  Direct3D 11 beta (`renderer = d3d11`, and the automatic fallback when
  OpenGL cannot start) adds hardware and WARP text rendering and hands images,
  custom shaders and background images to OpenGL; see
  [D3D11 renderer beta](windows.md#d3d11-renderer-beta).
- Window chrome is painted with GDI. The D3D11/DirectComposition +
  DirectWrite shell pipeline is not started at launch (its device graph cost
  about 156 ms to first swap and 79 driver threads for banner text alone; a
  noisy dev-machine measurement for #329, merged 2026-10-11, recorded in
  [ADR 0002](adr/0002-use-directcomposition-shell-with-retained-opengl-terminal.md));
  it never touches the terminal renderer.
- Presentation is power- and visibility-aware: focused non-saver cadence is
  unchanged, unfocused and saver pacing is capped, and minimized or
  DWM-cloaked windows stop presenting. Details and measurement fields are in
  [windows.md](windows.md#power-and-battery).

### Updater

- Checks the stable release feed (GitHub Releases by default, overridable
  with `auto-update-feed-url`) on launch, unless a check succeeded in the
  last 24 hours, and never replaces binaries silently. A copy left open checks
  again every six hours (the 24 hour limit still applies).
- `auto-update = download` stages only releases whose checksum metadata and
  Authenticode signatures both verify. Portable ZIPs additionally require a
  publisher-signed manifest covering every payload file; releases without it
  stay on the release-page path. Installer-managed installs launch the verified
  installer; portable installs apply a verified ZIP on the next launch and roll
  back an unconfirmed or failed startup. Applying a staged update is always
  user-initiated, and Install asks first when a terminal still has a running
  program. The relaunch after an installer-managed Install was checked by
  unit tests and the installer compile, not on a real install. Details in
  [windows.md](windows.md#updates).

### Windows package managers

- WinGet package id: `AmanThanvi.noctty` (published; `winget install --id AmanThanvi.noctty -e`).
- Chocolatey package id: `noctty` (published; `choco install noctty`).
  community.chocolatey.org approved 1.3.134 on 2026-10-23. The release
  workflow builds the package and its last step, after WinGet, pushes it; the
  repository variable `CHOCOLATEY_PUBLISH` was deleted on 2026-10-23, so the
  step runs on every release. Chocolatey reviews each version before listing
  it, so a release can reach it after the other channels. The community
  maintainer `virtualex`, who submitted `noctty` 1.3.131 on 2026-10-16, added
  `amanthanvi` as a maintainer on 2026-10-20 and stays on as a co-maintainer.
  The install script asks the CPU which installer to use, because Chocolatey
  runs as an emulated x64 process on ARM64 Windows; that ships with the first
  release built after 1.3.134, whose package installs the x64 build there. See
  [chocolatey-publishing.md](chocolatey-publishing.md). A released version is
  pushed with the manual Chocolatey Publish workflow.
- Scoop bucket: `https://github.com/amanthanvi/scoop-noctty`.

### Crash reports

- Crash dumps stay local under `%LOCALAPPDATA%\noctty\crash`. noctty never
  uploads anything from there, and the Sentry initialization path is a no-op
  on Windows.
- `noctty +crash-report` reads whatever is there. Releases from 1.3.133 on
  also publish a zip of debug symbols per architecture for reading a dump
  with a debugger; it is not in the installer or the portable ZIP. Details in
  [windows.md](windows.md#crash-reports-and-diagnostics).
- Unreadable session state is quarantined, never deleted, and repeated
  startup failures fall back to safe mode (a launch that ends only because
  OpenGL cannot start is not counted). A saved session that keeps ending
  the process during restore is renamed to `session-state.json.restore-failed`
  instead of being restored again. A restored session whose programs all
  ended by themselves before anyone used it is renamed to
  `session-state.json.restore-ended` instead of being saved back.
  Details in
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
Windows Terminal must stay selected as the console half. A handoff is served
by a separate `-Embedding` noctty process that opens its own window and has
no single-instance IPC, jump list or global hotkeys; it never reaches the
noctty you already have open, and elevated consoles were not verified. Details in
[windows.md](windows.md#default-terminal).

### Windows UI Automation (accessibility)

Covered: tabs expose TabItem with selection state; the new-tab and overflow
buttons have real names instead of their painted glyphs; the integrated
title bar's minimize, maximize/restore and close buttons are named, invokable
Button elements (since 1.3.125); the docked-search
toggles expose Toggle state; the search result count and host banners are
live regions; the terminal scrollbar exposes RangeValue; and the command
palette and settings sections expose list and selection semantics. Terminal
text is exposed through TextPattern/TextPattern2 with bounded ranges (up to
500 history rows within a 40,000-cell budget, plus the live viewport),
visible geometry, an accurate caret while the live screen remains inside
that bounded snapshot, and real selections. In deeper scrollback the
viewport remains available, but the off-window live caret is reported at
the document end. A text range's `ScrollIntoView` scrolls the terminal, and
each tab has a "Close tab" Button child; both are covered by unit
tests (and a one-off UI Automation client run recorded in #394), and neither
the interactive UI Automation harness nor the screen-reader matrix exercises
them.

Not yet covered: the profile picker and tab-overview overlay rows, context
menus, toasts, the tab drag preview, and quick-terminal chrome. `Ctrl+F6` and
`Ctrl+Shift+F6` (`cycle_focus_region`; a bare `F6` goes to the application)
move focus between the terminal, the tab strip, the docked search query and
the host banner, and `Escape` returns to the terminal. The cycle does not
reach the individual search buttons, the caption buttons (deliberately: they
are exposed through UIA but not keyboard-focusable), the profile picker, the
tab-overview rows or context menus.

No screen reader has been measured against a release yet. NVDA was measured
against a pre-release branch build, with mixed results: terminal text,
scrollbar, live regions, and banners read correctly; tab items, the search
flag toggles, and the docked search query edit do not announce their role,
state, or name. Per-widget expectations, what the automated UIA harness
proves, and per-reader results are in
[accessibility-matrix.md](accessibility-matrix.md).

### Link previews

`link-previews` is parsed and the shared core emits link-hover preview
actions, but the Win32 runtime does not render the preview tooltip. The
Settings control is disabled and says "not supported on Windows"; the config
key and tested hover tracker remain for compatibility and future wiring.
Link matching, hover highlighting, and opening work.

### Status bar

Removed. No terminal rows are reserved; host banners and overlays carry
transient status instead.

### Win32 runtime extraction

The Win32 runtime is still centered on one large file
(`src/apprt/win32.zig`). Extraction into focused modules is in progress and
lands incrementally.

## Known caveats

- Installers and the Windows binaries inside the portable ZIP are
  Authenticode-signed with a self-signed certificate; the ZIP container
  itself is checksummed, not signed. Windows shows no publisher identity and
  SmartScreen warns on first run, and that warning does not fade over time;
  see [getting-started.md](getting-started.md#about-the-smartscreen-warning)
  and [code-signing-policy.md](code-signing-policy.md). A release path for
  Azure Artifact Signing is in the workflow but switched off: preflight
  refuses it until the updater learns to trust its daily-rotating
  certificates, so no release uses it yet.
- GitHub Issues are for reproducible bugs. For questions, feature
  discussion, and feedback, use
  [Discussions](https://github.com/amanthanvi/noctty/discussions).
- OpenGL 4.3 through WGL is a floor for the default renderer. Below it, or
  when WGL fails, noctty falls back to the D3D11 beta (hardware, then WARP)
  with a banner; custom shaders, background images and Kitty images still need
  OpenGL 4.3. Only when D3D11 cannot start either does noctty show a startup
  diagnostic with the detected OpenGL version and the D3D11 error, and not
  start. Releases up to 1.3.132 counted those launches toward safe mode; see
  [windows.md](windows.md#starting-without-opengl) and
  [windows.md](windows.md#gpu-floor-and-opengl-driver-issues).
  On a Snapdragon PC that OpenGL comes from Microsoft's GLon12 mapping layer
  in the Compatibility Pack, not from a GPU vendor driver.
- No supported Linux application packaging. Upstream's Flatpak and Snap
  surfaces are removed; the curated Nix flake supports only `libghostty-vt`.
- A few generated artifacts still reference upstream: the `libghostty-vt`
  pkg-config `URL` field, the vim syntax-file headers, and a link in the
  generated bash completions point at `ghostty-org/ghostty`.
- Some upstream config keys are accepted and do nothing on Windows
  (`focus-follows-mouse`, `window-inherit-font-size`, `bell-features = border`, the
  GTK and X11 keys, and others); the list is in the
  [capability matrix](windows-capability-matrix.md#settings-accepted-without-effect).
- Crash capture is local-only, and some hard-abort paths may still
  terminate before Windows can produce a dump.
- With the bundled ConPTY, undo after `clear_screen` or `reset` restores the
  saved content shifted to the console's live cursor, and rows shifted above
  the screen go to scrollback, subject to its limit. ConPTY's own console
  buffer cannot be restored: an off-prompt `clear_screen` still discards the
  rows below the cursor (#401), so a console-buffer read or a program's later
  repaint can differ from the restored content. Shifting down to a later live
  row inserts blank rows above and can clip saved rows at the bottom. A clear
  the shell redraws itself (at a prompt) keeps the old undo behavior and can
  still leave noctty's cursor and ConPTY's apart until the shell clears
  again; a clear that is still queued when undo runs can erase the restored
  content. An alternate-screen snapshot keeps its whole picture and the live
  cursor, since it has no scrollback to take shifted rows. The application's
  own saved cursor (`ESC 7` / `ESC 8`) was not measured for undo.
- Cancel or Escape on an OSC 52 read prompt sends an empty reply, which has
  the same bytes as an allowed empty clipboard: Neovim can report an empty
  register on the next paste. Denial by `clipboard-read = deny`, and a prompt
  that another overlay replaced or whose tab was closed, send nothing, so a
  program waiting there waits for its own timeout (#353).
- Direct3D 11 beta: physical GPU reset, monitor hotplug and Remote Desktop
  were not measured. Real input was used on one two-monitor machine for a
  drag between DPIs, but its visible-desktop check used posted messages (#303).
  While the beta's notice banner is shown (about 5 s by default, the system's
  notification time) PresentMon on one machine showed the pane presented as
  composed flip; afterwards it was independent flip, whether or not the
  scrollbar was shown.
- A drag across monitors of different DPI reaches each visible pane of the
  active tab as one terminal resize, in the new font, at its final size
  (#426). Windows resizes the window before the new font is in, and the
  terminal could lay long lines out in that transient size and push them into
  scrollback. On main with #423, real drags (144 DPI to 96 DPI and back,
  150-column lines, logging what termio applied) sent an old-font size on
  30 of 30 drags and pushed lines into scrollback on 20. With the hold that
  #426 adds, 0 of 30. Its batched font and size were measured on a hidden
  desktop with a 60 ms delay injected after the font change, standing in for
  a slow font build in another pane: one resize per pane at its final grid,
  single pane and split, where the hold alone pushed lines on 29 of 30 moves.
  The two have not been measured together with real input. A tab hidden
  during the move takes the font and the size as separate resizes when it is
  shown, so a slow font build there can still wrap long lines into scrollback.
  A pane whose new font cannot be built gets the new size in the old font at
  once, which on a move to a lower DPI can do the same, and the font is
  retried on a later layout (both inferred, not measured).
- Alt+Space still sends ESC SPACE to the program as well as opening the
  window menu (#381). Once conhost has seen a Win32 input record it holds a
  lone ESC back until more input arrives, as under Windows Terminal (#335).
- Since 1.3.132 (#335) noctty sends keys to ConPTY as Win32 input records
  (unless the program asked for the Kitty keyboard protocol). A record's text
  is Windows' translation of the key against the keyboard state at key-down,
  not a `WM_CHAR` that follows it. So a tool that types into noctty by sending
  `WM_KEYDOWN` and then `WM_CHAR` to its window (`SendMessage`) without setting
  that keyboard state (for example with `AttachThreadInput` and
  `SetKeyboardState`) gets a Shift chord's unshifted character: Shift+.
  arrives as `.`, and the tool's `WM_CHAR` is dropped. Real keys, `SendInput`
  and IME commits are unaffected.
- A Japanese IME commit of 【】 freezes input in a `wslc exec -it` session
  (#395); reading wslc's source points at `wslc.exe` itself, not noctty (not
  reproduced with a real IME or container).
- Power- and visibility-aware render pacing has not been exercised on a
  machine with a battery (forced saver pacing, `power-saver-rendering = on`,
  has been measured, #297), and the DWM cloak/uncloak WinEvent path has not
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
  already recorded there, and UI Automation for overlay rows and menus.
- Keyboard reach for the chrome the focus-region cycle still skips (the
  search buttons, overlay rows and menus).
- Continuing the `src/apprt/win32.zig` extraction.
- Broader local crash metadata and report packaging.
- ARB-context OpenGL migration paired with atlas rebuild.

Contributions that advance any of the above are welcome.
