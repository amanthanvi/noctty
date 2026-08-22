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
- Ctrl-based default keybindings, mostly shared with Ghostty's
  non-macOS defaults; Windows-specific exceptions include `Alt+Arrow`
  pane focus and `Alt+F4` to close the window.
- Native settings window (Appearance, Terminal, Shell, Privacy, Updates,
  Keybindings, Advanced) that stages edits until Save and patches your
  config without rewriting unrelated text.
- Universal palette: actions, tabs, panes, profiles, themes, native
  settings, help, and recent commands in one fuzzy-searched,
  keyboard-driven list.

### Renderer

- Terminal content renders with OpenGL 4.3+ via WGL.
- Window chrome uses a separate D3D11/DirectComposition + DirectWrite
  pipeline with GDI fallback; it never touches the terminal renderer.

### Updater

- Checks the stable release feed (GitHub Releases by default, overridable with
  `auto-update-feed-url`) at most once every 24 hours and never replaces
  binaries silently.
- `auto-update = download` stages only releases that pass their checksum
  metadata plus Authenticode verification. Portable ZIPs additionally require
  a publisher-signed manifest covering every payload file; releases without it
  stay on the release-page path. Installer-managed installs launch the verified
  installer; portable installs apply a verified ZIP on the next launch and roll
  back an unconfirmed or failed startup. Applying a staged update is always
  user-initiated. Details in
  [windows.md](windows.md#updates).

### Windows package managers

- WinGet package id: `AmanThanvi.noctty`.
- Chocolatey package id: `noctty`.
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
through TextPattern/TextPattern2 with bounded ranges, visible geometry,
and an active caret anchor. The host and command palette expose focus
and selection semantics, while standard settings controls use native
HWND providers. Still to do: broader per-widget coverage and a full
Narrator/NVDA release matrix.

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
- Broader local crash metadata and report packaging.
- ARB-context OpenGL migration paired with atlas rebuild.

Contributions that advance any of the above are welcome.
