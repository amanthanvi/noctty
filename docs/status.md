# Status

What currently works in winghostty, what is experimental, and what is out of
scope. When this page disagrees with a commit message, trust this page.

Last updated: 2026-07-11, against current fork HEAD.

For a row-by-row mapping against official Ghostty docs, see
[windows-capability-matrix.md](windows-capability-matrix.md).
For Windows-specific install paths, app identity, shell behavior,
notifications, quick terminal notes, and troubleshooting, see
[windows.md](windows.md).

## Supported platform

- **Windows 10** and **Windows 11** — x64 and ARM64
- No macOS, Linux, or cross-platform app runtime ships from this repo.
  `libghostty-vt` remains buildable for non-Windows targets as a library.
- WSL _as a launched shell_ works when you opt in (`command = wsl.exe`).
  Implicit-default WSL is avoided because `wsl.exe --status` reporting
  healthy is not a reliable signal that a session launch will succeed
  (see `src/config/windows_shell.zig`).

## What works today

### Terminal core (shared with upstream Ghostty)

- VT parsing, screen / scrollback / alt-screen, DEC and xterm behaviors
- 256-color and true-color
- Bracketed paste, mouse tracking, OSC 8 hyperlinks, OSC 10 / 11 / 52.
  Windows has one native clipboard, so OSC 52 writes using selectors `c`, `s`,
  and `p` all target the standard Windows clipboard; OSC 52 read replies
  preserve the requested selector in the response.
- Bidi, combining marks, grapheme cluster rendering
- Kitty graphics protocol and inline image display
- Shell integration for bash, zsh, fish, PowerShell; `cmd.exe` is a plain
  fallback shell without prompt/cwd/command-finish integration
- Live config reload via keybind (`Ctrl+Shift+,`)
- `libghostty-vt` retained for Zig and C consumers

### Windows application runtime (new in this fork)

- Native Win32 message loop and window management
- Tab bar with overflow, same-window drag-reorder, and exact-pane drag-to-split.
  Drop previews name the resulting split direction; commits move the complete
  source split subtree through one reversible ShellState/native transaction.
  Undo and redo restore exact tab, pane, split-tree, ratio, focus, and control
  visibility. Cross-window OLE transfer remains a tested adapter foundation.
- Close-tab undo/redo retains exact tab, pane, split-tree, ratio, and focus
  identity. Retained history has bounded expiry and releases generational IDs
  only after an authoritative discard transaction succeeds.
- Horizontal and vertical splits
- Native right-click context menus
- In-app profile picker that auto-detects installed Windows shells:
  PowerShell, `cmd`, Git Bash, and opt-in WSL
- Per-monitor DPI scaling (`WM_DPICHANGED`)
- DWM dark title bar that follows the app theme
- High-contrast (HC) mode detection and palette switching
  (see `isHighContrastActive` in `src/apprt/win32.zig`)
- IME for CJK and other composed input (`ImmGetContext`)
- Sensitive-input indicator for password-style no-echo ConPTY input and the
  `toggle_secure_input` action. This is a local cursor/status/title affordance
  only; Windows does not provide the same Secure Keyboard Entry behavior that
  Ghostty uses on macOS, and winghostty does not block system-wide keyboard
  hooks.
- Drag-and-drop of files into the terminal (`WM_DROPFILES` +
  `DragAcceptFiles`)
- Window/session shape restore via `window-save-state`: host windows, tabs,
  splits, selected profiles, working directories, and explicit titles are
  persisted under `%LOCALAPPDATA%\winghostty\session-state.json`. Terminal
  contents and child process state are not restored.
- Windows-convention default keybindings (see
  `src/config/Config.zig` for the full set)
- Native settings window with Appearance, Terminal, Shell, Privacy, Updates,
  Keybindings, and Advanced sections. Edits are staged until Save and applied through an atomic,
  source-preserving config patch. Keybinding editing still opens the text config
  and points to CLI discovery commands. Ownership-safe fields support
  reversible live preview, revision-aware external-edit merging, and explicit
  field-conflict resolution.
- Universal palette blending configurable actions, live tabs, panes, Windows
  profiles, and exact native-setting controls. Typed stable IDs, category
  prefixes, fuzzy ranking, keyboard navigation, and a scrollable accessible
  result list ship. Reviewed help destinations and a snapshot-validated recent
  action provider also ship; installed-theme selection remains planned.

### Renderer

- OpenGL 4.3+ via WGL on Windows
- A concrete D3D11/DirectComposition shell driver owns a target, root visual,
  and DPI-sized DirectComposition surface for every top-level Host window.
  Direct2D/DirectWrite resources and per-window content recover across device
  loss, with WARP and truthful GDI fallback. The attached migration surface is
  transparent and the first isolated production zone—host banners and
  operation feedback—renders through DirectWrite. Any draw, commit, or recovery
  failure falls back to the proven GDI path for that paint. Remaining chrome
  zones stay on GDI/DWM; terminal presentation remains independently owned by
  WGL `SwapBuffers`.
- `src/renderer/Metal.zig` is inherited source but is unreachable from any
  shipping app runtime in this fork

### Updater

- Checks `api.github.com/repos/amanthanvi/winghostty/releases/latest`
- Never replaces the binary silently
- Gated to at most one check every 24 hours
- `auto-update = download` stages only Windows installer releases that include
  checksum metadata and pass SHA-256 plus Authenticode verification. Applying
  an installer-managed staged update requires a user click, re-verifies the
  staged installer, records apply intent, launches the installer elevated, and
  exits the app. Portable ZIP auto-apply is not implemented.

### Windows package managers

- WinGet package id: `AmanThanvi.winghostty`
- Scoop bucket: `https://github.com/amanthanvi/scoop-winghostty`
- Release readiness checks verify that both remote manifests exist before the
  release workflow is allowed to publish package-manager updates.

### Crash reports

- Local directory: `%LOCALAPPDATA%\winghostty\crash`
- **No automatic upload.** No code path to upload exists in this repo.
- On Windows the Sentry initialization path is a no-op
  (`src/crash/sentry.zig`), but winghostty installs a local
  unhandled-exception filter that writes `.dmp` minidumps through `DbgHelp`
  when Windows delivers a process-level crash exception.
- The `+crash-report` CLI reads anything that is there.

## Experimental / partial

### Windows UI Automation (accessibility)

UI Automation is **partial, not complete**. The Win32 host answers
`WM_GETOBJECT` with a root provider, caption buttons still chain through the
system host provider, the command palette exposes a list provider, and terminal
text is exposed read-only through `ITextProvider` / `ITextRangeProvider`.
Broader per-widget coverage and complete screen-reader validation remain
planned.

### Win32 runtime extraction

The Win32 application runtime is still centered on a single large file at
`src/apprt/win32.zig`. Extraction into focused modules is in progress:
commit `a759eb6 refactor(win32): extract theme module from monolithic
win32.zig` moved theme helpers to `src/apprt/win32_theme.zig`. Further
extractions will land as they stabilize.

## Known caveats

- **SmartScreen reputation.** Release artifacts are expected to be
  Authenticode-signed for the installer and Windows binaries inside the
  portable ZIP. The ZIP container itself is checksummed, not
  Authenticode-signed, and Windows SmartScreen can still warn for a new or
  low-reputation publisher certificate.
- **Issues disabled for usage questions.** GitHub Issues on this repo
  are reserved for reproducible bugs. For questions, feature discussion,
  and feedback, use
  [Discussions](https://github.com/amanthanvi/winghostty/discussions).
- **No Nix / Flatpak / Snap packaging.** Upstream's Linux packaging
  surfaces have been stubbed out or removed.
- **`build.zig.zon` identity.** The Zig package is still declared
  `.name = .ghostty`. Library consumers using Zig's package manager will
  see the upstream package name. Rename is planned.
- **Generated help links.** A few generated help strings still link to
  `github.com/ghostty-org/ghostty` rather than this fork. Tracked as a
  doc-generation fix.
- **Crash capture on Windows is local-only.** The Sentry path is gated off on
  Windows in `src/crash/sentry.zig`; local minidumps are written by
  `src/crash/minidump_windows.zig` for process-level unhandled exceptions. Some
  hard-abort paths may still terminate before Windows can produce a dump.
- **Startup recovery is local and non-destructive.** winghostty attempts to
  move unreadable session state to a timestamped sibling before startup opens
  a fresh window; if the filesystem move fails, the source remains untouched.
  Recent incomplete startups are counted in a bounded local schema; three
  consecutive failures select built-in configuration and skip session restore.
  `--safe-mode` provides the same ephemeral recovery path explicitly.
- **Diagnostic export is explicit.** `+diagnostic-bundle` creates a local,
  inspectable bundle. Terminal content, commands, environment, working
  directories, config values, and crash dumps are excluded by default.

## Out of scope

- macOS application packaging and Xcode workflows
- GTK / Linux / Wayland / X11 app-runtime work
- Flatpak, Snap, or other Linux desktop packaging
- Replicating upstream's community process or governance

## Informal roadmap signal

No formal roadmap. Indicative next areas:

- Broader UI Automation / screen reader coverage for application chrome and
  more per-widget support
- Continuing the `src/apprt/win32.zig` extraction begun in commit
  `a759eb6`
- Portable ZIP updater apply/rollback
- Broader local crash metadata and report packaging on Windows
- ARB-context OpenGL migration paired with atlas rebuild

Contributions that advance any of the above are welcome.
