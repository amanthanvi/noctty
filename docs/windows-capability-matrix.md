# Windows Capability Matrix

Maps current official Ghostty docs surfaces to noctty behavior on
Windows. Cells stay short; rows with real nuance point into the
[Notes](#notes) section below. Update rows when Windows behavior changes or
when upstream docs add or remove a surface that this fork cares about.

Last reviewed: 2026-09-02.

## Status legend

- `supported` — works on current Windows builds and matches upstream docs
  closely enough to rely on them.
- `partial` — some of the surface works, but Windows behavior is narrower,
  differently scoped, or still filling in.
- `windows-specific` — added or materially changed by this fork; upstream
  Ghostty docs do not describe it accurately yet.

## Supported

| Ghostty docs surface                                                                                               | noctty note                                                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Configuration](https://ghostty.org/docs/config) and [option reference](https://ghostty.org/docs/config/reference) | Same config grammar and generated docs. Config lives at `%LOCALAPPDATA%\noctty\config.ghostty`; live reload via `Ctrl+Shift+,`.                                                                                             |
| [Custom keybindings](https://ghostty.org/docs/config/keybind)                                                      | Same `keybind = trigger=action` grammar and `+list-keybinds` flow; defaults are the shared non-macOS set with Windows-specific exceptions.                                                                                  |
| [Color Theme](https://ghostty.org/docs/features/theme)                                                             | Built-in themes, separate light/dark themes, custom themes, and `+list-themes` ship on Windows.                                                                                                                             |
| [Configuration: `background-opacity`](https://ghostty.org/docs/config/reference)                                   | Transparent terminal backgrounds work on Windows and can be toggled live.                                                                                                                                                   |
| [Terminal API (VT)](https://ghostty.org/docs/vt) and [VT reference](https://ghostty.org/docs/vt/reference)         | The shared Ghostty terminal core carries the documented VT/OSC/Kitty surface. Win32-validated coverage: [windows-vt-conformance.md](windows-vt-conformance.md).                                                             |
| [Kitty keyboard protocol](https://ghostty.org/docs/vt)                                                             | Win32 supplies press, repeat, release, lock, and sided modifier state to the shared encoder. See [keyboard input](#keyboard-input).                                                                                         |
| [Features overview: windows, tabs, and splits](https://ghostty.org/docs/features)                                  | Native Win32 windows, tabs, and splits ship today in noctty.                                                                                                                                                                |
| [Configuration: `scrollbar`](https://ghostty.org/docs/config/reference)                                            | Per-pane graphical scrollbars honor `system` (Windows dynamic-scrollbar preference) or `never`; search matches appear as markers. See [search and scrollbars](#search-and-scrollbars).                                      |
| [Configuration: `notify-on-command-finish`](https://ghostty.org/docs/config/reference)                             | Focus policy, duration threshold, and bell/`notify` actions are applied; `notify` also needs `desktop-notifications`. See [notifications and progress](#notifications-and-progress).                                        |
| [Configuration: `clipboard-codepoint-map`](https://ghostty.org/docs/config/reference)                              | Selection copies apply the map before the clipboard write. See [clipboard and drag-drop](#clipboard-and-drag-drop).                                                                                                         |
| [Configuration: `clipboard-paste-protection`](https://ghostty.org/docs/config/reference)                           | Risky clipboard and dropped-content pastes use a native confirmation. See [clipboard and drag-drop](#clipboard-and-drag-drop).                                                                                              |
| [Action reference: `copy_to_clipboard:html`](https://ghostty.org/docs/config/keybind/reference)                    | HTML copy writes CF_HTML and a plain-text fallback in one clipboard transaction.                                                                                                                                            |
| Kitty graphics protocol                                                                                            | Parser and renderer support ship, but child APC delivery depends on ConPTY. The bundled source passed the measured payload byte-exactly; the tested in-box fallback stripped it. See [ConPTY transport](#conpty-transport). |

## Partial

| Ghostty docs surface                                                                         | noctty note                                                                                                                                                                                                                                                                                        |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Shell integration](https://ghostty.org/docs/features/shell-integration)                     | Upstream shell docs apply; Windows adds PowerShell injection and `cmd.exe` prompt/cwd marks. Clink is required for cmd command-finish marks and exit codes. See [shell integration notes](#shell-integration).                                                                                     |
| [Action reference](https://ghostty.org/docs/config/keybind/reference)                        | Shared action grammar is intact, but upstream mixes in macOS/Linux behavior. For Windows truth, prefer `+show-config --default --docs` plus `+list-keybinds`.                                                                                                                                      |
| [Action reference: `toggle_secure_input`](https://ghostty.org/docs/config/keybind/reference) | A local sensitive-input indicator only; no Windows equivalent of macOS Secure Keyboard Entry, and system-wide keyboard hooks are not blocked.                                                                                                                                                      |
| [Configuration: `auto-update`](https://ghostty.org/docs/config/reference)                    | Stable-release checking and prompts backed by GitHub Releases. `download` stages only installer releases that pass SHA-256 plus Authenticode verification; apply is user-initiated (UAC may prompt), and portable ZIP apply is not implemented. See [windows.md](windows.md#updates).              |
| [Configuration: `window-save-state`](https://ghostty.org/docs/config/reference)              | Persists windows, tabs, splits, profiles, working directories, and titles under `%LOCALAPPDATA%\noctty\session-state.json`. `window-save-state-scrollback` opts in to bounded plain-text pane snapshots; child processes are not restored.                                                         |
| [Configuration: `background-blur`](https://ghostty.org/docs/config/reference)                | Windows 11 22H2+ with `background-opacity < 1` requests the DWM tabbed backdrop; accepted but inert on Windows 10 and 11 21H2. Radii are treated as on/off.                                                                                                                                        |
| [Features overview](https://ghostty.org/docs/features)                                       | Accessibility is partial: UI Automation covers the daily chrome and terminal text, but caption buttons, overlay rows, and menus are uncovered. Only NVDA has been measured, with mixed results. See [accessibility notes](#accessibility) and the [screen-reader matrix](accessibility-matrix.md). |
| OSC 52 primary/selection clipboard selectors                                                 | Windows has one native clipboard: writes with selectors `c`, `s`, and `p` all target it; read replies still echo the requested selector.                                                                                                                                                           |
| [Configuration: `link-previews`](https://ghostty.org/docs/config/reference)                  | Link matching, highlighting, and opening work, but the Win32 runtime does not render the preview tooltip.                                                                                                                                                                                          |
| [Configuration: `key-remap`](https://ghostty.org/docs/config/reference)                      | Focused and in-app keybinds plus terminal encoding honor remaps; `global:` hotkeys keep the literal configured chord. See [keyboard input](#keyboard-input).                                                                                                                                       |

## Windows-Specific

| Ghostty docs surface                                                              | noctty note                                                                                                                                                                                                          |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Features overview](https://ghostty.org/docs/features)                            | Upstream docs still say Windows support is planned. noctty ships a native Win32 app on Windows 10/11 x64 and ARM64.                                                                                                  |
| Elevated windows                                                                  | Separate `runas` windows with integrity-scoped IPC and no elevated session restore. See [Running elevated](windows.md#running-elevated).                                                                             |
| [Features overview: GPU-accelerated rendering](https://ghostty.org/docs/features) | Terminal content renders with OpenGL 4.3+ via WGL. See [renderer notes](#renderer).                                                                                                                                  |
| [Configuration](https://ghostty.org/docs/config)                                  | Windows state/config paths live under `%LOCALAPPDATA%\noctty\...`, not the macOS/Linux paths documented upstream.                                                                                                    |
| Local automation                                                                  | Versioned JSON state and stable local verbs for windows, tabs, splits, focus, policy-allowed actions, and control-free text. See [automation.md](automation.md).                                                     |
| [Features overview](https://ghostty.org/docs/features)                            | Win32-specific UX: DWM dark caption, high-contrast palette switching, IME, and native context menus.                                                                                                                 |
| Integrated title bar                                                              | Windows 11 uses app-owned caption chrome with native caption actions and Snap Layout hover while the tab bar and decorations are visible; `window-show-tab-bar = never` and older builds use the stock caption.      |
| Universal palette                                                                 | One blended, fuzzy-ranked command surface. See [universal palette notes](#universal-palette).                                                                                                                        |
| Named layouts                                                                     | Saves one window's tab/split/profile/cwd/title shape and materializes it in a new window from keybind, palette, or CLI.                                                                                              |
| Quick select and copy mode                                                        | Visible regex targets plus modal keyboard selection and scrollback navigation. See [windows.md](windows.md#quick-select--copy-mode).                                                                                 |
| Native settings                                                                   | A native settings window with staged, source-preserving saves. See [native settings notes](#native-settings).                                                                                                        |
| Tab dragging                                                                      | Same-window reorder and exact-pane drag-to-split. See [tab dragging notes](#tab-dragging).                                                                                                                           |
| Power-aware rendering                                                             | `unfocused-render-fps` caps visible background presentation; `power-saver-rendering` controls saver pacing; minimized and DWM-cloaked windows do not present. See [power and battery](windows.md#power-and-battery). |
| SSH host discovery                                                                | Concrete aliases from `%USERPROFILE%\.ssh\config` appear as system `ssh.exe` launch entries in the picker and palette.                                                                                               |
| Windows default terminal                                                          | `+register-default-terminal` selects noctty per user through the Windows Terminal 1.24-or-newer OpenConsole handoff; see [windows.md](windows.md#default-terminal).                                                  |
| Taskbar jump lists                                                                | Recent working directories and detected shell profiles launch from the pinned or running taskbar button. See [taskbar jump list](windows.md#taskbar-jump-list).                                                      |
| Quick terminal and global hotkeys                                                 | Configurable edge/center terminal toggled by a bindable action; `global:` bindings use `RegisterHotKey`. See [quick terminal](#quick-terminal).                                                                      |
| Desktop notifications                                                             | WinRT Action Center toasts with a local fallback; only command-finish toasts have a click action. See [notifications and progress](#notifications-and-progress).                                                     |
| Taskbar progress                                                                  | Terminal progress reports drive the active pane's taskbar indicator when `progress-style` is enabled. See [notifications and progress](#notifications-and-progress).                                                 |
| Docked search                                                                     | Each pane has a docked scrollback search with regex, case, whole-word, navigation, and scrollbar markers. See [search and scrollbars](#search-and-scrollbars).                                                       |
| Tab overview                                                                      | The bindable `toggle_tab_overview` action opens a numeric tab switcher; it has no default keybind.                                                                                                                   |
| Drag and drop                                                                     | Each pane accepts files, plain text, URLs, and HTML. See [clipboard and drag-drop](#clipboard-and-drag-drop).                                                                                                        |
| Opt-in child-process limits                                                       | Retained `linux-cgroup*` keys map to Job Objects for Windows-local children only. See [child-process limits](#child-process-limits).                                                                                 |

## Notes

### ConPTY transport

Packaged builds prefer the side-by-side ConPTY redistributable and fall back to
the in-box conhost with a warning. `+version` and the diagnostic-bundle manifest
report the active source. On this machine the bundled source delivered measured
Kitty APC and Sixel DCS payloads byte-for-byte; the in-box source dropped both.
See the generation-specific
[transport catalog](windows-vt-conformance.md#conpty-transport-generations-and-mangling-catalog).

### Shell integration

Upstream docs for automatic `bash` / `elvish` / `fish` / `nushell` / `zsh`
injection still apply when those shells are launched on Windows. On top of
that:

- Automatic PowerShell injection (`powershell.exe`, `pwsh.exe`), with a
  manual fallback at
  `%LOCALAPPDATA%\noctty\shell-integration\powershell\integration.ps1`.
- PowerShell emits OSC 7 cwd URIs, OSC 133 prompt marks, command-finish
  status, and PSReadLine command metadata when available.
- OSC 133 prompt marks back previous/next prompt navigation, copying the last
  completed command output, and rerunning the last recoverable single-line
  command from the command palette. Rerun requires OSC 133;B and OSC 133;C;
  it does not inspect or modify the shell's line editor.
- PowerShell wraps `ssh` for `ssh-env` and cache-aware `ssh-terminfo`, but
  does not auto-install remote terminfo; uncached hosts use
  `xterm-256color`.
- Automatic `cmd.exe` integration wraps the existing `PROMPT` (or cmd's
  `$P$G` default) to emit OSC 133 A/B prompt marks and OSC 9;9 cwd reports.
  When Clink is detected, noctty prepends its shipped Lua directory to
  `CLINK_PATH`; an already-active Clink can then load it and emit OSC 133 C/D
  command marks and exit codes. Noctty does not activate Clink. Without the
  loaded Clink script, prompt/cwd marks still work but command-finish marks and
  exit codes are unavailable.

### Keyboard input

The Win32 path supplies press, repeat, and release events to the shared Kitty
encoder, with Caps Lock, Num Lock, and left/right modifier state on every
physical event. While a client has Kitty `report_all` enabled, ordinary keys
carry their text on the physical event instead of the `WM_CHAR` commit, so
press and release keep one identity; AltGr chords ride the same path with the
synthetic Ctrl+Alt collapsed, a dead key stays composing until its composed
character arrives, and a dead key that cannot combine delivers both
characters. IME commits remain text without a physical key. These paths have
unit coverage but have not been exercised on a real non-US keyboard.

`key-remap` changes modifier state before focused or in-app keybind matching
and terminal encoding; it does not change physical key identity. `global:`
bindings register the literal configured chord through `RegisterHotKey`, so
remaps do not retarget system-wide hotkeys.

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
does not replace or call the terminal renderer. The terminal path has a hard
OpenGL 4.3-via-WGL floor and no software fallback; below it, noctty shows a
startup diagnostic naming the detected version and does not launch.

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

No default keybind. Bind `toggle_quick_terminal`; add the `global:` prefix
for a system-wide hotkey while noctty is running. Windows can reject a
reserved or conflicting trigger. Position, size, monitor, animation,
autohide, and focus behavior are configurable. `exclusive` maps to focused
input, and `quick-terminal-space-behavior` has no Windows effect.

### Notifications and progress

WinRT toasts use noctty's AppUserModelID and fall back to a host banner, then
the log, when native delivery fails. `desktop-notifications` gates every
toast. Command-finish toasts additionally need `notify-on-command-finish` and
a `notify-on-command-finish-action` that includes `notify`; they are the only
toasts that carry a launch argument, so only they focus the originating pane
when clicked. OSC 9 / OSC 777 toasts are display-only. Reliable cold-start
activation depends on the installed Start menu shortcut.
`notify-on-command-finish-after` and the focus policy are applied before the
bell or toast; command marks come from shell integration or OSC 133, which
`cmd.exe` does not supply.

With `progress-style = true`, terminal progress reports map to normal, paused,
error, or indeterminate taskbar states for the active pane in each host. If
the taskbar COM interface fails, noctty disables the native indicator.

### Search and scrollbars

`Ctrl+Shift+F` opens search for the focused pane. Search state and controls
are per pane; results can mark the graphical scrollbar. `scrollbar = system`
respects Windows' dynamic-scrollbar preference and stays visible in High
Contrast; `never` removes only the visual widget.

### Clipboard and drag-drop

`clipboard-paste-protection` controls confirmation for unsafe clipboard
pastes and the stricter dropped-payload classifier. CF_HTML copies also place
a plain-text fallback on the clipboard. Dropped files, text, URLs, and HTML
are converted to terminal input. Shift changes file/text handling, Ctrl
suppresses file-path quoting, and Alt is reserved.

`clipboard-codepoint-map` is applied by the shared selection formatter before
plain, VT, or HTML bytes reach the clipboard. Clipboard reads, URL copies,
OSC 52 writes, and `write_screen_file` exports are not mapped.

### Child-process limits

The retained `linux-cgroup`, `linux-cgroup-memory-limit`,
`linux-cgroup-processes-limit`, and `linux-cgroup-hard-fail` keys opt
Windows-local launches into Job Object enforcement. Off by default;
best-effort failures continue without limits unless hard-fail is set.
`windows-job-object-kill-on-close` is also opt-in. WSL launches are excluded.

## Maintenance Anchors

- `src/config/Config.zig` — config docs, keybinds, feature gates, and limits.
- `src/termio/shell_integration.zig` and `src/config/windows_shell.zig` —
  shell integration and Windows shell detection.
- `src/apprt/win32.zig`, `src/apprt/win32_quick_terminal.zig`,
  `src/apprt/win32_search_bar.zig`, and
  `src/apprt/win32_scrollbar_geometry.zig` — Win32 runtime and interactive UI.
- `src/apprt/win32_toast_winrt.zig`, `src/apprt/win32_toast_activation.zig`,
  `src/apprt/win32_aumid.zig`, and `src/apprt/win32_taskbar_progress.zig` —
  notifications and shell progress.
- `src/apprt/win32_clipboard_html.zig`, `src/apprt/win32_paste_protection.zig`,
  `src/apprt/win32_surface_drop_target.zig`, and
  `src/apprt/win32_job_object.zig` — clipboard, drop, and process limits.
- `src/apprt/win32_theme.zig` and `src/apprt/win32_uia/` — theme policy and
  accessibility providers.
- `docs/status.md` and `docs/getting-started.md` — user-facing summaries that
  should stay aligned with this matrix.
