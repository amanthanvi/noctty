# Windows Capability Matrix

Maps current official Ghostty docs surfaces to noctty behavior on
Windows. Cells stay short; rows with real nuance point into the
[Notes](#notes) section below. Update rows when Windows behavior changes or
when upstream docs add or remove a surface that this fork cares about.

Last reviewed: 2026-08-21, against every module under `src/apprt/` and its
`src/config/Config.zig` surface.

## Status legend

- `supported` — works on current Windows builds and matches upstream docs
  closely enough to rely on them.
- `partial` — some of the surface works, but Windows behavior is narrower,
  differently scoped, or still filling in.
- `windows-specific` — added or materially changed by this fork; upstream
  Ghostty docs do not describe it accurately yet.

## Supported

| Ghostty docs surface                                                                                               | noctty note                                                                                                                                                     |
| ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Configuration](https://ghostty.org/docs/config) and [option reference](https://ghostty.org/docs/config/reference) | Same config grammar and generated docs. Config lives at `%LOCALAPPDATA%\noctty\config.ghostty`; live reload via `Ctrl+Shift+,`.                                 |
| [Custom keybindings](https://ghostty.org/docs/config/keybind)                                                      | Same `keybind = trigger=action` grammar and `+list-keybinds` flow; defaults are the shared non-macOS set with Windows-specific exceptions.                      |
| [Color Theme](https://ghostty.org/docs/features/theme)                                                             | Built-in themes, separate light/dark themes, custom themes, and `+list-themes` ship on Windows.                                                                 |
| [Configuration: `background-opacity`](https://ghostty.org/docs/config/reference)                                   | Transparent terminal backgrounds work on Windows and can be toggled live.                                                                                       |
| [Terminal API (VT)](https://ghostty.org/docs/vt) and [VT reference](https://ghostty.org/docs/vt/reference)         | The shared Ghostty terminal core carries the documented VT/OSC/Kitty surface. Win32-validated coverage: [windows-vt-conformance.md](windows-vt-conformance.md). |
| [Features overview: windows, tabs, and splits](https://ghostty.org/docs/features)                                  | Native Win32 windows, tabs, and splits ship today in noctty.                                                                                                    |
| [Configuration: `scrollbar`](https://ghostty.org/docs/config/reference)                                            | Per-pane graphical scrollbars support Windows system/dynamic visibility or `never`; search matches appear as markers.                                           |
| [Configuration: `clipboard-paste-protection`](https://ghostty.org/docs/config/reference)                           | Risky clipboard and dropped-content pastes use a native confirmation surface. Bracketed-paste safety remains separately configurable.                           |
| [Action reference: `copy_to_clipboard:html`](https://ghostty.org/docs/config/keybind/reference)                    | HTML copy writes Windows CF_HTML and a plain-text fallback in one clipboard transaction.                                                                        |

## Partial

| Ghostty docs surface                                                                         | noctty note                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Shell integration](https://ghostty.org/docs/features/shell-integration)                     | Upstream shell docs apply; PowerShell injection is added on Windows, `cmd.exe` stays a plain fallback. See [shell integration notes](#shell-integration).                                                                                                                             |
| [Action reference](https://ghostty.org/docs/config/keybind/reference)                        | Shared action grammar is intact, but upstream mixes in macOS/Linux behavior. For Windows truth, prefer `+show-config --default --docs` plus `+list-keybinds`.                                                                                                                         |
| [Action reference: `toggle_secure_input`](https://ghostty.org/docs/config/keybind/reference) | A local sensitive-input indicator only; no Windows equivalent of macOS Secure Keyboard Entry, and system-wide keyboard hooks are not blocked.                                                                                                                                         |
| [Configuration: `auto-update`](https://ghostty.org/docs/config/reference)                    | Stable-release checking and prompts backed by GitHub Releases. `download` stages only installer releases that pass SHA-256 plus Authenticode verification; apply is user-initiated (UAC may prompt), and portable ZIP apply is not implemented. See [windows.md](windows.md#updates). |
| [Configuration: `window-save-state`](https://ghostty.org/docs/config/reference)              | Persists windows, tabs, splits, profiles, working directories, and titles under `%LOCALAPPDATA%\noctty\session-state.json`. Terminal contents and child processes are not restored.                                                                                                   |
| [Configuration: `background-blur`](https://ghostty.org/docs/config/reference)                | Windows 11 22H2+ with `background-opacity < 1` requests the DWM tabbed backdrop; accepted but inert on Windows 10 and 11 21H2. Radii are treated as on/off.                                                                                                                           |
| [Features overview](https://ghostty.org/docs/features)                                       | Accessibility is partial. See [accessibility notes](#accessibility).                                                                                                                                                                                                                  |
| OSC 52 primary/selection clipboard selectors                                                 | Windows has one native clipboard: writes with selectors `c`, `s`, and `p` all target it; read replies still echo the requested selector.                                                                                                                                              |
| [Configuration: `link-previews`](https://ghostty.org/docs/config/reference)                  | Link matching, highlighting, and opening work, but the Win32 runtime does not render the configured preview tooltip.                                                                                                                                                                  |

## Windows-Specific

| Ghostty docs surface                                                              | noctty note                                                                                                                                                                  |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Features overview](https://ghostty.org/docs/features)                            | noctty ships a native Win32 app on Windows 10/11 x64 and ARM64.                                                                                                              |
| [Features overview: GPU-accelerated rendering](https://ghostty.org/docs/features) | Terminal content renders with OpenGL 4.3+ via WGL. See [renderer notes](#renderer).                                                                                          |
| [Configuration](https://ghostty.org/docs/config)                                  | Windows state/config paths live under `%LOCALAPPDATA%\noctty\...`, not the macOS/Linux paths documented upstream.                                                            |
| Local automation                                                                  | `+list-windows` JSON plus allowlisted `+perform-action` over single-instance IPC. See [windows.md](windows.md#automation).                                                   |
| Integrated title bar                                                              | Windows 11 uses app-owned caption chrome with native caption actions and Snap Layout hover when the tab bar and decorations are visible; older builds use the stock caption. |
| [Features overview](https://ghostty.org/docs/features)                            | Win32-specific UX: DWM dark-mode handling, high-contrast palette switching, IME, and native context menus.                                                                   |
| Universal palette                                                                 | One blended, fuzzy-ranked command surface. See [universal palette notes](#universal-palette).                                                                                |
| Native settings                                                                   | A native settings window with staged, source-preserving saves. See [native settings notes](#native-settings).                                                                |
| Tab dragging                                                                      | Same-window reorder and exact-pane drag-to-split. See [tab dragging notes](#tab-dragging).                                                                                   |
| Quick terminal and global hotkeys                                                 | Configurable edge/center terminal toggled by a bindable action; `global:` bindings use `RegisterHotKey`. See [quick-terminal notes](#quick-terminal).                        |
| Desktop notifications                                                             | WinRT Action Center toasts with a local fallback; only command-finish toasts have a click action. See [notification and progress notes](#notification-and-progress).         |
| Taskbar progress                                                                  | Terminal progress reports drive the active pane's taskbar indicator in each host window. See [notification and progress notes](#notification-and-progress).                  |
| Docked search                                                                     | Each pane has a docked scrollback search UI with regex, case, whole-word, navigation, and scrollbar markers. See [search and scrollbars notes](#search-and-scrollbars).      |
| Tab overview                                                                      | The bindable `toggle_tab_overview` action opens a numeric tab switcher; it has no default keybind.                                                                           |
| Drag and drop                                                                     | Each pane accepts files, plain text, URLs, and HTML. See [clipboard and drag-drop notes](#clipboard-and-drag-drop).                                                          |
| Opt-in child-process limits                                                       | Retained `linux-cgroup*` keys map to Job Objects for Windows-local children only. See [child-process-limit notes](#child-process-limits).                                    |

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

The Win32 host exposes a UI Automation root provider. The command palette,
docked-search query, and native Settings controls expose custom or native
roles and interaction patterns. Terminal text is available read-only through
TextPattern/TextPattern2 with at most 500 recent rows and an approximate
40,000-cell history budget, plus the active viewport. Arbitrary terminal
selection mutation and UIA `ScrollIntoView` are not implemented. Broader
application-chrome coverage and screen-reader validation remain incomplete.

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

### Quick terminal

There is no default keybind. Bind `toggle_quick_terminal`; add the `global:`
prefix for a system-wide hotkey while noctty is running. Windows can reject a
reserved or conflicting trigger. Position, size, monitor selection, animation,
autohide, and focus behavior are configurable. `exclusive` maps to focused
input, and `quick-terminal-space-behavior` has no Windows effect.

### Notification and progress

WinRT toasts use noctty's AppUserModelID and fall back to a host banner, then
the log, when native delivery fails. Only command-finish toasts carry a launch
argument, so only those focus the originating surface when clicked; terminal
notifications from OSC 9 / OSC 777 are display-only. Reliable cold-start
activation depends on the installed Start menu shortcut. `desktop-notifications` gates
terminal notifications, while command-finish notifications have their own
settings.

With `progress-style = true`, terminal progress reports map to normal, paused,
error, or indeterminate taskbar states for the active pane in each host. If the
taskbar COM interface fails, noctty disables the native indicator.

### Search and scrollbars

`Ctrl+Shift+F` opens search for the focused pane. Search state and controls are
per pane; results stay newest-first and can mark the graphical scrollbar.
`scrollbar = system` respects Windows' dynamic-scrollbar preference and uses
auto-hide animation when enabled; `never` removes only the visual widget.

### Clipboard and drag-drop

`clipboard-paste-protection` controls confirmation for unsafe clipboard
pastes and the stricter dropped-payload classifier. CF_HTML copies also place
a plain-text fallback on the clipboard. Dropped files, text, URLs, and HTML
are converted to terminal input. Shift changes file/text handling, Ctrl
suppresses file-path quoting, and Alt is reserved.

### Child-process limits

The retained `linux-cgroup`, `linux-cgroup-memory-limit`,
`linux-cgroup-processes-limit`, and `linux-cgroup-hard-fail` keys can opt
Windows-local launches into Job Object enforcement. The default is off;
best-effort failures continue without limits unless hard-fail is set.
`windows-job-object-kill-on-close` is also opt-in. WSL launches are excluded.

## Maintenance Anchors

- `src/config/Config.zig` — config docs, keybinds, feature gates, and limits.
- `src/termio/shell_integration.zig` and `src/config/windows_shell.zig` —
  shell integration and Windows shell detection.
- `src/apprt/win32.zig`, `src/apprt/win32_quick_terminal.zig`,
  `src/apprt/win32_search_bar.zig`, and
  `src/apprt/win32_scrollbar_geometry.zig` — Win32 runtime and interactive UI.
- `src/apprt/win32_toast_winrt.zig`,
  `src/apprt/win32_toast_activation.zig`, `src/apprt/win32_aumid.zig`, and
  `src/apprt/win32_taskbar_progress.zig` — notifications and shell progress.
- `src/apprt/win32_clipboard_html.zig`,
  `src/apprt/win32_paste_protection.zig`,
  `src/apprt/win32_surface_drop_target.zig`, and
  `src/apprt/win32_job_object.zig` — clipboard, drop, and process limits.
- `src/apprt/win32_theme.zig` and `src/apprt/win32_uia/` — theme policy and
  accessibility providers.
- `docs/status.md` and `docs/getting-started.md` — user-facing summaries that
  should stay aligned with this matrix.
