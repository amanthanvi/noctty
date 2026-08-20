# Windows Capability Matrix

Maps current official Ghostty docs surfaces to winghostty behavior on
Windows. Cells stay short; rows with real nuance point into the
[Notes](#notes) section below. Update rows when Windows behavior changes or
when upstream docs add or remove a surface that this fork cares about.

Last reviewed: 2026-08-19.

## Status legend

- `supported` — works on current Windows builds and matches upstream docs
  closely enough to rely on them.
- `partial` — some of the surface works, but Windows behavior is narrower,
  differently scoped, or still filling in.
- `windows-specific` — added or materially changed by this fork; upstream
  Ghostty docs do not describe it accurately yet.

## Supported

| Ghostty docs surface                                                                                               | winghostty note                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Configuration](https://ghostty.org/docs/config) and [option reference](https://ghostty.org/docs/config/reference) | Same config grammar and generated docs. Config lives at `%LOCALAPPDATA%\winghostty\config.ghostty`; live reload via `Ctrl+Shift+,`.                             |
| [Custom keybindings](https://ghostty.org/docs/config/keybind)                                                      | Same `keybind = trigger=action` grammar and `+list-keybinds` flow; defaults are the shared non-macOS set with Windows-specific exceptions.                      |
| [Color Theme](https://ghostty.org/docs/features/theme)                                                             | Built-in themes, separate light/dark themes, custom themes, and `+list-themes` ship on Windows.                                                                 |
| [Configuration: `background-opacity`](https://ghostty.org/docs/config/reference)                                   | Transparent terminal backgrounds work on Windows and can be toggled live.                                                                                       |
| [Terminal API (VT)](https://ghostty.org/docs/vt) and [VT reference](https://ghostty.org/docs/vt/reference)         | The shared Ghostty terminal core carries the documented VT/OSC/Kitty surface. Win32-validated coverage: [windows-vt-conformance.md](windows-vt-conformance.md). |
| [Features overview: windows, tabs, and splits](https://ghostty.org/docs/features)                                  | Native Win32 windows, tabs, and splits ship today in winghostty.                                                                                                |

## Partial

| Ghostty docs surface                                                                         | winghostty note                                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Shell integration](https://ghostty.org/docs/features/shell-integration)                     | Upstream shell docs apply; PowerShell injection is added on Windows. `cmd.exe` gets OSC 133 A/B + OSC 9;9 from `PROMPT`; C/D marks require Clink. See [shell integration notes](#shell-integration).                                                                                   |
| [Action reference](https://ghostty.org/docs/config/keybind/reference)                        | Shared action grammar is intact, but upstream mixes in macOS/Linux behavior. For Windows truth, prefer `+show-config --default --docs` plus `+list-keybinds`.                                                                                                                         |
| [Action reference: `toggle_secure_input`](https://ghostty.org/docs/config/keybind/reference) | A local sensitive-input indicator only; no Windows equivalent of macOS Secure Keyboard Entry, and system-wide keyboard hooks are not blocked.                                                                                                                                         |
| [Configuration: `auto-update`](https://ghostty.org/docs/config/reference)                    | Stable-release checking and prompts backed by GitHub Releases. `download` stages only installer releases that pass SHA-256 plus Authenticode verification; apply is user-initiated (UAC may prompt), and portable ZIP apply is not implemented. See [windows.md](windows.md#updates). |
| [Configuration: `window-save-state`](https://ghostty.org/docs/config/reference)              | Persists windows, tabs, splits, profiles, working directories, and titles under `%LOCALAPPDATA%\winghostty\session-state.json`. Terminal contents and child processes are not restored.                                                                                               |
| [Configuration: `background-blur`](https://ghostty.org/docs/config/reference)                | Windows 11 22H2+ with `background-opacity < 1` requests the DWM tabbed backdrop; accepted but inert on Windows 10 and 11 21H2. Radii are treated as on/off.                                                                                                                           |
| [Features overview](https://ghostty.org/docs/features)                                       | Accessibility is partial. See [accessibility notes](#accessibility).                                                                                                                                                                                                                  |
| OSC 52 primary/selection clipboard selectors                                                 | Windows has one native clipboard: writes with selectors `c`, `s`, and `p` all target it; read replies still echo the requested selector.                                                                                                                                              |

## Windows-Specific

| Ghostty docs surface                                                              | winghostty note                                                                                                            |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| [Features overview](https://ghostty.org/docs/features)                            | Upstream docs still say Windows support is planned. winghostty ships a native Win32 app on Windows 10/11 x64 and ARM64.    |
| [Features overview: GPU-accelerated rendering](https://ghostty.org/docs/features) | Terminal content renders with OpenGL 4.3+ via WGL. Below that floor, startup fails with a visible dialog. See [renderer notes](#renderer) and [windows.md](windows.md#gpu-floor).          |
| [Configuration](https://ghostty.org/docs/config)                                  | Windows state/config paths live under `%LOCALAPPDATA%\winghostty\...`, not the macOS/Linux paths documented upstream.      |
| Local automation                                                                  | `+list-windows` JSON plus allowlisted `+perform-action` over single-instance IPC. See [windows.md](windows.md#automation). |
| [Features overview](https://ghostty.org/docs/features)                            | Win32-specific UX: DWM dark title bar, high-contrast palette switching, IME, drag-and-drop, and native context menus.      |
| Universal palette                                                                 | One blended, fuzzy-ranked command surface. See [universal palette notes](#universal-palette).                              |
| Native settings                                                                   | A native settings window with staged, source-preserving saves. See [native settings notes](#native-settings).              |
| Tab dragging                                                                      | Same-window reorder and exact-pane drag-to-split. See [tab dragging notes](#tab-dragging).                                 |
| Quick terminal                                                                    | `toggle_quick_terminal` plus `quick-terminal-*` config; global binds via `RegisterHotKey`. See [windows.md](windows.md#quick-terminal-and-global-hotkeys). |
| Desktop notifications                                                             | WinRT toasts first, host banner fallback. See [windows.md](windows.md#notifications-and-progress).                         |
| Taskbar progress                                                                  | OSC 9;4 maps to `ITaskbarList3` progress on the host HWND.                                                                 |
| Docked scrollback search                                                          | Per-pane search bar with regex / case / word / wrap.                                                                       |
| Link preview                                                                      | Hover-dwell tooltip for OSC 8 URLs.                                                                                        |
| Paste protection                                                                  | Core unsafe-paste confirm plus Win32 classifier on clipboard and drag-drop. See [windows.md](windows.md#paste-path-security). |
| Jump lists                                                                        | `ICustomDestinationList` recent directories from OSC 7 / 9;9.                                                              |
| Explorer "Open here"                                                              | Classic HKCU verbs on Directory and Directory\\Background.                                                                 |
| Prompt-mark navigation                                                            | Palette + default `jump_to_prompt` binds; copy-last-output and re-run last command.                                        |
| UTF-8 console preamble                                                            | `utf8-console = auto\|always\|never`; auto skips legacy CJK ANSI code pages.                                               |

## Notes

### Shell integration

Upstream docs for automatic `bash` / `elvish` / `fish` / `nushell` / `zsh`
injection still apply when those shells are launched on Windows. On top of
that:

- Automatic PowerShell injection (`powershell.exe`, `pwsh.exe`), with a
  manual fallback at
  `%LOCALAPPDATA%\winghostty\shell-integration\powershell\integration.ps1`.
- PowerShell emits OSC 7 cwd URIs, OSC 133 prompt marks, command-finish
  status, and PSReadLine command metadata when available.
- PowerShell wraps `ssh` for `ssh-env` and cache-aware `ssh-terminfo`, but
  does not auto-install remote terminfo; uncached hosts use
  `xterm-256color`.
- `cmd.exe` automatic integration sets `PROMPT` for OSC 133 A/B and
  OSC 9;9 cwd. Command-start (C) and exit-code (D) marks load only
  when Clink is on PATH (`src/shell-integration/cmd/clink.lua`).
- `utf8-console = auto|always|never` applies a UTF-8 console preamble
  (`chcp 65001` for cmd, `[Console]::OutputEncoding` for PowerShell).
  `auto` refuses to force UTF-8 on legacy CJK ANSI code pages.

### Accessibility

The Win32 host exposes a UI Automation root provider, the command palette
exposes a list provider, and terminal text is available read-only through
`ITextProvider` / `ITextRangeProvider`. Broader application-chrome coverage
and screen-reader validation remain incomplete.

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
