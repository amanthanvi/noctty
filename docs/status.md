# Status

What currently works in winghostty, what is experimental, and what is out of
scope. When this page disagrees with a commit message, trust this page.

Last updated: 2026-07-11, against current fork HEAD.

For a row-by-row mapping against official Ghostty docs (including the
implementation nuance this page deliberately leaves out), see
[windows-capability-matrix.md](windows-capability-matrix.md). For Windows
paths, shells, updates, automation, and troubleshooting, see
[windows.md](windows.md).

## Supported platform

- **Windows 10** and **Windows 11** — x64 and ARM64.
- No macOS, Linux, or cross-platform app runtime ships from this repo;
  `libghostty-vt` stays buildable for non-Windows targets as a library.
- WSL works as a launched shell when you opt in (`command = wsl.exe`); it is
  never picked implicitly (see [windows.md](windows.md#shells) for why).

## What works today

### Terminal core (shared with upstream Ghostty)

- VT parsing, screen / scrollback / alt-screen, DEC and xterm behaviors.
- 256-color and true-color.
- Bracketed paste, mouse tracking, OSC 8 hyperlinks, OSC 10 / 11 / 52 (all
  OSC 52 selectors target the single native Windows clipboard).
- Bidi, combining marks, grapheme cluster rendering.
- Kitty graphics protocol and inline image display.
- Shell integration for bash, zsh, fish, PowerShell; `cmd.exe` is a plain
  fallback without prompt/cwd/command-finish integration.
- Live config reload via keybind (`Ctrl+Shift+,`).
- `libghostty-vt` retained for Zig and C consumers.

Win32-validated VT protocol coverage is tracked in
[windows-vt-conformance.md](windows-vt-conformance.md).

### Windows application runtime (new in this fork)

- Native Win32 windows, tab bar with overflow, and drag: same-window tab
  reorder and exact-pane drag-to-split, with full undo/redo.
- Horizontal and vertical splits.
- Close-tab undo/redo that restores the exact tab, panes, and layout.
- Native right-click context menus.
- In-app profile picker for detected shells: PowerShell, `cmd`, Git Bash,
  and opt-in WSL.
- Per-monitor DPI scaling.
- DWM dark title bar that follows the app theme.
- High-contrast mode detection and palette switching.
- IME for CJK and other composed input.
- A local sensitive-input indicator for no-echo input (`toggle_secure_input`
  is a visual affordance only; it does not block system-wide keyboard hooks
  the way macOS Secure Keyboard Entry does).
- Drag-and-drop of files into the terminal.
- Session restore via `window-save-state`: windows, tabs, splits, profiles,
  working directories, and explicit titles come back — terminal contents and
  child processes do not.
- Windows-convention default keybindings.
- Native settings window (Appearance, Terminal, Shell, Privacy, Updates,
  Keybindings, Advanced) that stages edits until Save and patches your
  config without rewriting unrelated text.
- Universal palette: actions, tabs, panes, profiles, themes, and native
  settings in one fuzzy-searched, keyboard-driven list.

### Renderer

- Terminal content renders with OpenGL 4.3+ via WGL.
- Window chrome uses a separate D3D11/DirectComposition + DirectWrite
  pipeline with GDI fallback; it never touches the terminal renderer.

### Updater

- Checks `api.github.com/repos/amanthanvi/winghostty/releases/latest`, at
  most once every 24 hours, and never replaces binaries silently.
- `auto-update = download` stages only releases that pass checksum metadata
  plus Authenticode verification; applying a staged update is always
  user-initiated. Details in [windows.md](windows.md#updates).

### Windows package managers

- WinGet package id: `AmanThanvi.winghostty`.
- Scoop bucket: `https://github.com/amanthanvi/scoop-winghostty`.

### Crash reports

- Crash dumps stay local under `%LOCALAPPDATA%\winghostty\crash` — **no
  automatic upload**, and no code path to upload exists in this repo.
- `winghostty +crash-report` reads whatever is there. Details in
  [windows.md](windows.md#crash-reports-and-diagnostics).

## Experimental / partial

### Windows UI Automation (accessibility)

UI Automation is **partial, not complete**. Terminal text is exposed read-only
through TextPattern/TextPattern2 with bounded ranges, visible geometry, and an
active caret anchor. The host and command palette expose focus and selection
semantics, while standard settings controls use native HWND providers. Broader
per-widget coverage and the full Narrator/NVDA release matrix remain required.

### Win32 runtime extraction

The Win32 runtime is still centered on a single large file
(`src/apprt/win32.zig`). Extraction into focused modules is in progress and
lands incrementally.

## Known caveats

- **SmartScreen reputation.** Installers and the Windows binaries inside the
  portable ZIP are Authenticode-signed; the ZIP container itself is
  checksummed, not Authenticode-signed. SmartScreen can still warn for a new
  or low-reputation publisher certificate.
- **Issues are for reproducible bugs.** For questions, feature discussion,
  and feedback, use
  [Discussions](https://github.com/amanthanvi/winghostty/discussions).
- **No Nix / Flatpak / Snap packaging.** Upstream's Linux packaging surfaces
  are removed.
- **Generated help links.** A few generated help strings still link to
  `github.com/ghostty-org/ghostty` rather than this fork.
- **Crash capture is local-only.** Some hard-abort paths may still terminate
  before Windows can produce a dump.
- **Startup recovery is non-destructive.** Unreadable session state is
  quarantined, never deleted; repeated startup failures fall back to safe
  mode. Details in [windows.md](windows.md#session-restore-and-recovery).
- **Diagnostic export is explicit.** `+diagnostic-bundle` redacts sensitive
  data by default.

## Out of scope

- macOS application packaging and Xcode workflows.
- GTK / Linux / Wayland / X11 app-runtime work.
- Flatpak, Snap, or other Linux desktop packaging.
- Replicating upstream's community process or governance.

## Informal roadmap signal

No formal roadmap. Indicative next areas:

- Broader UI Automation / screen reader coverage.
- Continuing the `src/apprt/win32.zig` extraction.
- Portable ZIP updater apply/rollback.
- Broader local crash metadata and report packaging.
- ARB-context OpenGL migration paired with atlas rebuild.

Contributions that advance any of the above are welcome.
