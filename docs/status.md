# Status

What currently works in noctty, what is experimental, and what is out
of scope. When this page disagrees with a commit message, trust this
page.

Last updated: 2026-08-21, after a module-by-module audit of `src/apprt/`
and its `src/config/Config.zig` surfaces.

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
- Kitty keyboard protocol input includes press, repeat, and release events,
  Caps Lock, Num Lock, and left/right physical modifier state.
- Shell integration for bash, zsh, fish, elvish, nushell, and PowerShell
  (PowerShell through `shell-integration = detect`); `cmd.exe` is a
  plain fallback without prompt/cwd/command-finish integration.
- Live config reload via keybind (`Ctrl+Shift+,`).
- `libghostty-vt` retained for Zig and C consumers.

Win32-validated VT protocol coverage is tracked in
[windows-vt-conformance.md](windows-vt-conformance.md).

### Windows application runtime (new in this fork)

- Native Win32 windows, tab bar with overflow, a numeric tab overview,
  and drag: same-window tab reorder and exact-pane drag-to-split.
- Horizontal and vertical splits.
- Structural undo/redo for new splits, single-tab close (restoring the
  exact tab, panes, and layout), and drag-to-split subtree transfers.
  Tab reorder and multi-tab close modes are not undoable.
- Native right-click context menus.
- In-app profile picker for detected shells: PowerShell 7, Windows
  PowerShell, `cmd`, Git Bash, and WSL distributions when WSL responds.
- Per-monitor DPI scaling.
- DWM dark caption that follows the app theme on all supported builds,
  plus an integrated title bar on Windows 11 with native caption actions
  and Snap Layout hover. Older builds use the stock caption.
- High-contrast mode detection and palette switching.
- IME for CJK and other composed input.
- A local sensitive-input indicator for no-echo input
  (`toggle_secure_input` is a visual affordance only; it does not block
  system-wide keyboard hooks the way macOS Secure Keyboard Entry does).
- Drag-and-drop of files, plain text, URLs, and HTML into a pane. Shift
  changes file/text handling, Ctrl suppresses file-path quoting, and Alt
  has no assigned behavior.
- A per-pane docked scrollback search bar with regex, case-sensitive, and
  whole-word modes, result navigation, and match markers on the scrollbar.
- Per-pane graphical scrollbars. `scrollbar = system` follows Windows'
  dynamic-scrollbar preference; `never` hides the widget without disabling
  scrolling.
- Clipboard paste confirmation for risky content, including dropped
  payloads, gated by `clipboard-paste-protection`. HTML copy writes both
  Windows CF_HTML and a plain-text fallback. `clipboard-codepoint-map` applies
  to plain, VT, and HTML selection copies; clipboard reads, URL copies, OSC 52
  writes, and `write_screen_file` exports are unchanged.
- A configurable quick terminal on the top, bottom, left, right, or center
  of the selected monitor area. It has no default binding; `global:`
  keybinds use `RegisterHotKey`. `exclusive` keyboard interactivity falls
  back to focused input, and virtual-desktop following is not implemented.
- WinRT Action Center notifications with an in-app banner/log fallback
  when WinRT cannot show a toast. Command-finish toasts focus the
  originating surface when clicked; other toasts, including OSC 9 and OSC
  777 notifications, have no click action. Packaged Start menu identity is
  required for reliable cold-start activation. Command-finish focus policy,
  duration threshold, and bell/`notify` actions are honored when shell
  integration or OSC 133 supplies command marks.
- Windows taskbar progress for the active pane in each host window, driven
  by terminal progress reports when `progress-style` is enabled.
- Session restore via `window-save-state`: windows, tabs, splits,
  profiles, working directories, and explicit titles come back; terminal
  contents and child processes do not.
- Ctrl-based default keybindings, mostly shared with Ghostty's
  non-macOS defaults; Windows-specific exceptions include `Alt+Arrow`
  pane focus and `Alt+F4` to close the window.
- `key-remap` affects focused and in-app keybinds plus terminal encoding, but
  does not change physical key identity. Win32 `global:` hotkeys keep the
  literal configured chord.
- Native settings window (Appearance, Terminal, Shell, Privacy, Updates,
  Keybindings, Advanced) that stages edits until Save and patches your
  config without rewriting unrelated text.
- Universal palette: actions, tabs, panes, profiles, themes, native
  settings, help, and recent commands in one fuzzy-searched,
  keyboard-driven list.
- Opt-in Windows Job Object limits for Windows-local child processes via
  the retained `linux-cgroup`, `linux-cgroup-memory-limit`,
  `linux-cgroup-processes-limit`, and `linux-cgroup-hard-fail` settings.
  They are off by default and do not cover WSL process trees.

### Renderer

- Terminal content renders with OpenGL 4.3+ via WGL.
- Window chrome uses a separate D3D11/DirectComposition + DirectWrite
  pipeline with GDI fallback; it never touches the terminal renderer.

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

UI Automation coverage is partial. Terminal text is exposed read-only
through TextPattern/TextPattern2 with bounded recent history, visible
geometry, and an active caret anchor. The host, command palette list and
query, docked-search query, and native Settings controls expose roles,
values, focus, invoke, or selection semantics where applicable. Arbitrary
terminal selection mutation and UIA `ScrollIntoView` are not implemented;
broader per-widget coverage and a full Narrator/NVDA release matrix remain.

### Link previews

`link-previews` is parsed and the shared terminal core emits link-hover
preview actions, but the Win32 runtime does not render the preview tooltip.
Link matching, hover highlighting, and opening still work.

### Status bar

Not shipping. `Host.statusBarHeight()` returns 0, so no terminal rows are
reserved and the status paint paths are inert. Transient status is carried by
host banners and overlays instead.

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
- No supported Linux packaging. Upstream's Flatpak and Snap surfaces
  are removed; the Nix files left over from upstream are untested and
  unsupported here.
- A few generated artifacts still reference upstream: the
  `libghostty-vt` pkg-config `URL` field, the vim syntax-file headers,
  and a link in the generated bash completions point at
  `ghostty-org/ghostty`.
- Crash capture is local-only, and some hard-abort paths may still
  terminate before Windows can produce a dump.

## Out of scope

- macOS application packaging and Xcode workflows.
- GTK / Linux / Wayland / X11 app-runtime work.
- Flatpak, Snap, or other Linux desktop packaging.
- Replicating upstream's community process or governance.

## What's next

No formal roadmap. Likely next areas:

- Broader UI Automation / screen reader coverage.
- Continuing the `src/apprt/win32.zig` extraction.
- Portable ZIP updater apply/rollback.
- Broader local crash metadata and report packaging.
- ARB-context OpenGL migration paired with atlas rebuild.

Contributions that advance any of the above are welcome.
