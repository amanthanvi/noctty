# Windows Capability Matrix

Maps current official Ghostty docs surfaces to noctty behavior on
Windows. Cells stay short; rows with real nuance point into the
[Notes](#notes) section below. Update rows when Windows behavior changes or
when upstream docs add or remove a surface that this fork cares about.

Last reviewed: 2026-08-21.

## Status legend

- `supported` — works on current Windows builds and matches upstream docs
  closely enough to rely on them.
- `partial` — some of the surface works, but Windows behavior is narrower,
  differently scoped, or still filling in.
- `windows-specific` — added or materially changed by this fork; upstream
  Ghostty docs do not describe it accurately yet.

## Supported

| Ghostty docs surface                                                                                               | noctty note                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Configuration](https://ghostty.org/docs/config) and [option reference](https://ghostty.org/docs/config/reference) | Same config grammar and generated docs. Config lives at `%LOCALAPPDATA%\noctty\config.ghostty`; live reload via `Ctrl+Shift+,`.                             |
| [Custom keybindings](https://ghostty.org/docs/config/keybind)                                                      | Same `keybind = trigger=action` grammar and `+list-keybinds` flow; defaults are the shared non-macOS set with Windows-specific exceptions.                      |
| [Color Theme](https://ghostty.org/docs/features/theme)                                                             | Built-in themes, separate light/dark themes, custom themes, and `+list-themes` ship on Windows.                                                                 |
| [Configuration: `background-opacity`](https://ghostty.org/docs/config/reference)                                   | Transparent terminal backgrounds work on Windows and can be toggled live.                                                                                       |
| [Terminal API (VT)](https://ghostty.org/docs/vt) and [VT reference](https://ghostty.org/docs/vt/reference)         | The shared Ghostty terminal core carries the documented VT/OSC/Kitty surface. Win32-validated coverage: [windows-vt-conformance.md](windows-vt-conformance.md). |
| [Features overview: windows, tabs, and splits](https://ghostty.org/docs/features)                                  | Native Win32 windows, tabs, and splits ship today in noctty.                                                                                                |

## Partial

| Ghostty docs surface                                                                         | noctty note                                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Shell integration](https://ghostty.org/docs/features/shell-integration)                     | Upstream shell docs apply; PowerShell injection is added on Windows, `cmd.exe` stays a plain fallback. See [shell integration notes](#shell-integration).                                                                                                                             |
| [Action reference](https://ghostty.org/docs/config/keybind/reference)                        | Shared action grammar is intact, but upstream mixes in macOS/Linux behavior. For Windows truth, prefer `+show-config --default --docs` plus `+list-keybinds`.                                                                                                                         |
| [Action reference: `toggle_secure_input`](https://ghostty.org/docs/config/keybind/reference) | A local sensitive-input indicator only; no Windows equivalent of macOS Secure Keyboard Entry, and system-wide keyboard hooks are not blocked.                                                                                                                                         |
| [Configuration: `auto-update`](https://ghostty.org/docs/config/reference)                    | Stable-release checking and prompts backed by GitHub Releases. `download` stages only installer releases that pass SHA-256 plus Authenticode verification; apply is user-initiated (UAC may prompt), and portable ZIP apply is not implemented. See [windows.md](windows.md#updates). |
| [Configuration: `window-save-state`](https://ghostty.org/docs/config/reference)              | Persists windows, tabs, splits, profiles, working directories, and titles under `%LOCALAPPDATA%\noctty\session-state.json`. Terminal contents and child processes are not restored.                                                                                               |
| [Configuration: `background-blur`](https://ghostty.org/docs/config/reference)                | Windows 11 22H2+ with `background-opacity < 1` requests the DWM tabbed backdrop; accepted but inert on Windows 10 and 11 21H2. Radii are treated as on/off.                                                                                                                           |
| [Features overview](https://ghostty.org/docs/features)                                       | Accessibility is partial: UI Automation covers the daily chrome and terminal text, but caption buttons, overlay rows, and menus are uncovered. Only NVDA has been measured, with mixed results. See [accessibility notes](#accessibility) and the [screen-reader matrix](accessibility-matrix.md).  |
| OSC 52 primary/selection clipboard selectors                                                 | Windows has one native clipboard: writes with selectors `c`, `s`, and `p` all target it; read replies still echo the requested selector.                                                                                                                                              |

## Windows-Specific

| Ghostty docs surface                                                              | noctty note                                                                                                            |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| [Features overview](https://ghostty.org/docs/features)                            | Upstream docs still say Windows support is planned. noctty ships a native Win32 app on Windows 10/11 x64 and ARM64.    |
| [Features overview: GPU-accelerated rendering](https://ghostty.org/docs/features) | Terminal content renders with OpenGL 4.3+ via WGL. See [renderer notes](#renderer).                                        |
| [Configuration](https://ghostty.org/docs/config)                                  | Windows state/config paths live under `%LOCALAPPDATA%\noctty\...`, not the macOS/Linux paths documented upstream.      |
| Local automation                                                                  | `+list-windows` JSON plus allowlisted `+perform-action` over single-instance IPC. See [windows.md](windows.md#automation). |
| [Features overview](https://ghostty.org/docs/features)                            | Win32-specific UX: DWM dark title bar, high-contrast palette switching, IME, drag-and-drop, and native context menus.      |
| Universal palette                                                                 | One blended, fuzzy-ranked command surface. See [universal palette notes](#universal-palette).                              |
| Named layouts                                                                     | Saves one window's tab/split/profile/cwd/title shape and materializes it in a new window from keybind, palette, or CLI.     |
| Native settings                                                                   | A native settings window with staged, source-preserving saves. See [native settings notes](#native-settings).              |
| Tab dragging                                                                      | Same-window reorder and exact-pane drag-to-split. See [tab dragging notes](#tab-dragging).                                 |
| Power-aware rendering                                                             | `unfocused-render-fps` caps visible background presentation; `power-saver-rendering` controls saver pacing; minimized and DWM-cloaked windows do not present. See [power and battery](windows.md#power-and-battery). |
| SSH host discovery                                                                | Concrete aliases from `%USERPROFILE%\.ssh\config` appear as system `ssh.exe` launch entries in the picker and palette.    |
| Windows default terminal                                                          | `+register-default-terminal` selects noctty per user through the Windows Terminal 1.24-or-newer OpenConsole handoff; see [windows.md](windows.md#default-terminal). |
| Taskbar jump lists                                                                | Recent working directories and detected shell profiles launch from the pinned or running taskbar button.                   |

## Notes

### Shell integration

Upstream docs for automatic `bash` / `elvish` / `fish` / `nushell` / `zsh`
injection still apply when those shells are launched on Windows. On top of
that:

- Automatic PowerShell injection (`powershell.exe`, `pwsh.exe`), with a
  manual fallback at
  `%LOCALAPPDATA%\noctty\shell-integration\powershell\integration.ps1`.
- PowerShell emits OSC 7 cwd URIs, OSC 133 prompt marks, command-finish
  status, and PSReadLine command metadata when available.
- PowerShell wraps `ssh` for `ssh-env` and cache-aware `ssh-terminfo`, but
  does not auto-install remote terminfo; uncached hosts use
  `xterm-256color`.
- `cmd.exe` remains a plain fallback shell without automatic integration.

### Accessibility

The Win32 host exposes a UI Automation root provider; tabs, the new-tab and
overflow buttons, docked-search controls, the search result count, host
banners, and the terminal scrollbar expose per-widget providers with the
patterns their roles require; the command palette and settings sections
expose list and selection semantics; and terminal text is available through
`ITextProvider` / `ITextRangeProvider` / `ITextProvider2` including real
selections. Caption buttons, overlay rows, menus, and toasts are still
uncovered. Only NVDA has been measured, on a pre-release branch build,
and several chrome elements do not announce their role or state through
it — see the [screen-reader matrix](accessibility-matrix.md).

### Renderer

Terminal presentation is owned by WGL `SwapBuffers`. A separate
D3D11/DirectComposition shell pipeline owns recoverable top-level targets and
transparent DPI-sized D2D surfaces; host banner and operation text is the
first DirectWrite production zone, with per-paint GDI fallback. That pipeline
does not replace or call the terminal renderer.

### Universal palette

Configurable actions, live tabs, panes, Windows profiles, installed themes,
native settings, reviewed help destinations, and keyboard tab-to-pane moves
share one typed, fuzzy-ranked list with:

- category prefixes (`>`, `@`, `/`, `~`, `:`, `%`, `!`, `?`) and keyboard
  navigation
- stable dispatch IDs and destructive/disabled semantics
- UI Automation selection announcements
- reversible live theme preview before commit (High Contrast suppresses
  cosmetic previews but still allows an explicit commit)
- a snapshot-validated recent-action provider

### Native settings

Appearance, Terminal, Shell, Privacy, Updates, Keybindings, and Advanced
sections ship. Edits are staged until Save and applied through an atomic,
source-preserving config patch; Advanced shows the pending field diff and
keeps the plain-text escape hatch. Owned snapshots survive external reloads,
and native fields support reversible live preview, revision-aware
external-edit merging, and explicit Keep mine / Use disk conflict
resolution. Keybinding editing still uses the text config and CLI discovery
commands.

### Tab dragging

Same-window reorder and DPI-aware exact-pane drag-to-split ship, with
operation-labeled drop previews. Transfers move the complete source split
subtree through one authoritative ShellState/native transaction, and undo /
redo restore exact tab, pane, split-tree, ratio, and focus identity. The
universal palette provides the equivalent keyboard workflow. Cross-window
OLE transfer is not shipped.

## Maintenance Anchors

- `src/config/Config.zig` — config docs, keybinds, `auto-update` docstrings.
- `src/termio/shell_integration.zig` and `src/config/windows_shell.zig` —
  shell integration and Windows shell detection.
- `src/apprt/win32.zig`, `src/apprt/win32_theme.zig`, and
  `src/apprt/win32_uia/` — Win32 runtime, chrome/input, accessibility.
- `docs/status.md` and `docs/getting-started.md` — user-facing summaries that
  should stay aligned with this matrix.
