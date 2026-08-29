# Status

What currently works in noctty, what is experimental, and what is out
of scope. When this page disagrees with a commit message, trust this
page.

Last updated: 2026-08-12, against current fork HEAD.

For a row-by-row mapping against official Ghostty docs (including the
implementation nuance this page deliberately leaves out), see
[windows-capability-matrix.md](windows-capability-matrix.md). For Windows
paths, shells, updates, automation, and troubleshooting, see
[windows.md](windows.md).

## Supported platform

- Windows 10 and Windows 11, on x64 and ARM64.
- No macOS, Linux, or cross-platform app runtime ships from this repo;
  `libghostty-vt` stays buildable for non-Windows targets as a library.
- WSL sessions work from the profile picker; becoming the default shell
  requires an explicit `command = wsl.exe` (see
  [windows.md](windows.md#shells) for why).

## What works today

### Terminal core (shared with upstream Ghostty)

- VT parsing, screen / scrollback / alt-screen, DEC and xterm behaviors.
- 256-color and true-color.
- Bracketed paste, mouse tracking, OSC 8 hyperlinks, OSC 10 / 11 / 52
  (all OSC 52 selectors target the single native Windows clipboard).
- Bidi, combining marks, grapheme cluster rendering.
- Kitty graphics protocol and inline image display.
- Shell integration for bash, zsh, fish, elvish, nushell, and PowerShell
  (PowerShell through `shell-integration = detect`); `cmd.exe` is a
  plain fallback without prompt/cwd/command-finish integration.
- Live config reload via keybind (`Ctrl+Shift+,`).
- `libghostty-vt` retained for Zig and C consumers.

Win32-validated VT protocol coverage is tracked in
[windows-vt-conformance.md](windows-vt-conformance.md).

### Windows application runtime (new in this fork)

- Native Win32 windows, tab bar with overflow, and drag: same-window tab
  reorder and exact-pane drag-to-split.
- Horizontal and vertical splits.
- Structural undo/redo for new splits, single-tab close (restoring the
  exact tab, panes, and layout), and drag-to-split subtree transfers.
  Tab reorder and multi-tab close modes are not undoable.
- Native right-click context menus.
- In-app profile picker for detected shells: PowerShell 7, Windows
  PowerShell, `cmd`, Git Bash, and WSL distributions when WSL responds.
- Concrete aliases from `%USERPROFILE%\.ssh\config` appear in the profile
  picker and universal palette and launch through the system `ssh.exe`.
- Per-monitor DPI scaling.
- DWM dark title bar that follows the app theme.
- High-contrast mode detection and palette switching.
- IME for CJK and other composed input.
- A local sensitive-input indicator for no-echo input
  (`toggle_secure_input` is a visual affordance only; it does not block
  system-wide keyboard hooks the way macOS Secure Keyboard Entry does).
- Drag-and-drop of files into the terminal.
- Session restore via `window-save-state`: windows, tabs, splits,
  profiles, working directories, and explicit titles come back; terminal
  contents and child processes do not.
- Named layouts (C17): save the focused window's tabs, splits, profiles,
  working directories, and titles, then launch it in a new window from a
  keybind, the universal palette, or `+new-window --launch-layout=<name>`.
- Ctrl-based default keybindings, mostly shared with Ghostty's
  non-macOS defaults; Windows-specific exceptions include `Alt+Arrow`
  pane focus and `Alt+F4` to close the window.
- Native settings window (Appearance, Terminal, Shell, Privacy, Updates,
  Keybindings, Advanced) that stages edits until Save and patches your
  config without rewriting unrelated text.
- Universal palette: actions, tabs, panes, profiles, named layouts, themes, native
  settings, help, and recent commands in one fuzzy-searched,
  keyboard-driven list.

### Renderer

- Terminal content renders with OpenGL 4.3+ via WGL.
- Window chrome uses a separate D3D11/DirectComposition + DirectWrite
  pipeline with GDI fallback; it never touches the terminal renderer.
- Presentation is power- and visibility-aware: focused non-saver cadence
  is unchanged, unfocused and saver pacing is capped, and minimized or
  DWM-cloaked windows stop presenting. Details and measurement fields are
  in [windows.md](windows.md#power-and-battery).

### Updater

- Checks `api.github.com/repos/amanthanvi/noctty/releases/latest`, at
  most once every 24 hours, and never replaces binaries silently.
- `auto-update = download` stages only releases that pass their
  checksum metadata plus Authenticode verification; applying a staged
  update is always user-initiated. Details in
  [windows.md](windows.md#updates).

### Windows package managers

- WinGet package id: `AmanThanvi.noctty`.
- Scoop bucket: `https://github.com/amanthanvi/scoop-noctty`.

### Crash reports

- Crash dumps stay local under `%LOCALAPPDATA%\noctty\crash`. There
  is no automatic upload, and no code path to upload exists in this repo.
- `noctty +crash-report` reads whatever is there. Details in
  [windows.md](windows.md#crash-reports-and-diagnostics).
- Unreadable session state is quarantined, never deleted, and repeated
  startup failures fall back to safe mode; details in
  [windows.md](windows.md#session-restore-and-recovery).
- `+diagnostic-bundle` exports are explicit and redact terminal content,
  environment, and config values by default.

## Experimental / partial

### Windows UI Automation (accessibility)

UI Automation covers the window chrome a screen-reader user touches
daily. Tabs expose TabItem with selection state, the new-tab and
overflow buttons have real names instead of their painted glyphs, the
docked-search toggles expose Toggle state, the search result count and
host banners are live regions, and the terminal scrollbar exposes
RangeValue. Terminal text is exposed through TextPattern/TextPattern2
with bounded ranges (500 history rows plus the live viewport), visible
geometry, a caret that stays truthful while scrolled back, and real
selections. The command palette and settings sections expose list and
selection semantics.

Not yet covered: custom-painted caption buttons, the profile picker and
tab-overview overlay rows, context menus, toasts, and quick-terminal
chrome. There is also no keyboard focus-region cycle, so chrome cannot
be reached from the terminal without a mouse.

No screen reader has been measured against a release yet. The per-widget
expectations, what the automated UIA harness proves, and the empty
Narrator/NVDA/JAWS columns are published in
[accessibility-matrix.md](accessibility-matrix.md).

### Win32 runtime extraction

The Win32 runtime is still centered on a single large file
(`src/apprt/win32.zig`). Extraction into focused modules is in progress
and lands incrementally.

## Known caveats

- Installers and the Windows binaries inside the portable ZIP are
  Authenticode-signed; the ZIP container itself is checksummed, not
  signed. SmartScreen can still warn for a new or low-reputation
  publisher certificate; see
  [getting-started.md](getting-started.md#about-the-smartscreen-warning).
- GitHub Issues are for reproducible bugs. For questions, feature
  discussion, and feedback, use
  [Discussions](https://github.com/amanthanvi/noctty/discussions).
- No supported Linux application packaging. Upstream's Flatpak and Snap
  surfaces are removed; the curated Nix flake supports only `libghostty-vt`.
- A few generated artifacts still reference upstream: the
  `libghostty-vt` pkg-config `URL` field, the vim syntax-file headers,
  and a link in the generated bash completions point at
  `ghostty-org/ghostty`.
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

- Measured Narrator/NVDA/JAWS results for the
  [screen-reader matrix](accessibility-matrix.md), plus UI Automation
  for caption buttons, overlay rows, and menus.
- A keyboard focus-region cycle so window chrome is reachable without a
  mouse.
- Continuing the `src/apprt/win32.zig` extraction.
- Portable ZIP updater apply/rollback.
- Broader local crash metadata and report packaging.
- ARB-context OpenGL migration paired with atlas rebuild.

Contributions that advance any of the above are welcome.
