# Windows Capability Matrix

Maps current official Ghostty docs surfaces to winghostty behavior on
Windows. Keep this short. Update rows when Windows behavior changes or when
upstream docs add or remove a surface that this fork cares about.

Last reviewed: 2026-05-01.

## Status legend

- `supported` — works on current Windows builds and matches upstream docs
  closely enough to rely on them.
- `partial` — some of the surface works, but Windows behavior is narrower,
  differently scoped, or still filling in.
- `no-op compatibility` — the option or surface exists for compatibility,
  but currently reduces to placeholder or weaker behavior.
- `windows-specific` — added or materially changed by this fork; upstream
  Ghostty docs do not describe it accurately yet.

## Supported

| Ghostty docs surface | winghostty note |
| --- | --- |
| [Configuration](https://ghostty.org/docs/config) and [option reference](https://ghostty.org/docs/config/reference) | Same config grammar and generated docs surface. On Windows the config file lives at `%LOCALAPPDATA%\winghostty\config.ghostty`, and live reload is available via `Ctrl+Shift+,`. |
| [Custom keybindings](https://ghostty.org/docs/config/keybind) | Same `keybind = trigger=action` grammar and `+list-keybinds` flow. Default bindings are Windows-native rather than macOS/Linux defaults. |
| [Color Theme](https://ghostty.org/docs/features/theme) | Built-in themes, separate light/dark themes, custom themes, and `+list-themes` ship on Windows. |
| [Terminal API (VT)](https://ghostty.org/docs/vt) and [VT reference](https://ghostty.org/docs/vt/reference) | The shared Ghostty terminal core carries the documented VT/OSC/Kitty surface used by terminal apps. |
| [Features overview: windows, tabs, and splits](https://ghostty.org/docs/features) | Native Win32 windows, tabs, and splits ship today in winghostty. |

## Partial

| Ghostty docs surface | winghostty note |
| --- | --- |
| [Shell integration](https://ghostty.org/docs/features/shell-integration) | Upstream docs for automatic `bash` / `elvish` / `fish` / `nushell` / `zsh` injection still apply when those shells are launched on Windows. winghostty additionally supports automatic PowerShell injection (`powershell.exe`, `pwsh.exe`) plus a manual fallback under `%LOCALAPPDATA%\winghostty\shell-integration\powershell\integration.ps1`, which upstream docs do not cover. |
| [Action reference](https://ghostty.org/docs/config/keybind/reference) | Shared action grammar is intact, but upstream docs still mix shared actions with macOS/Linux-specific behavior. For Windows-specific truth on a disputed action, prefer `winghostty +show-config --default --docs` plus the current defaults from `+list-keybinds`. |
| [Configuration: `auto-update`](https://ghostty.org/docs/config/reference) | Windows supports stable-release checking and notify-only update prompts backed by GitHub Releases. Background download/install behavior is not implemented. |
| [Features overview](https://ghostty.org/docs/features) | Accessibility is partial: the Win32 host exposes a UI Automation root provider and the command palette exposes a list provider, but terminal scrollback is not yet exposed through `ITextProvider`. |

## No-op Compatibility

| Ghostty docs surface | winghostty note |
| --- | --- |
| [Configuration: `auto-update = download`](https://ghostty.org/docs/config/reference) | Accepted on Windows, but today behaves the same as `auto-update = check`; no background download or install path runs. |

## Windows-Specific

| Ghostty docs surface | winghostty note |
| --- | --- |
| [Features overview](https://ghostty.org/docs/features) | Upstream Ghostty docs still say Windows support is planned. winghostty ships a native Win32 app on Windows 10/11 x64. |
| [Features overview: GPU-accelerated rendering](https://ghostty.org/docs/features) | Upstream highlights Metal on macOS and OpenGL on Linux. winghostty renders on Windows with OpenGL 4.3+ via WGL; no D3D/DirectX backend ships. |
| [Configuration](https://ghostty.org/docs/config) | Windows state/config paths live under `%LOCALAPPDATA%\winghostty\...`, not the macOS/Linux paths documented upstream. |
| [Features overview](https://ghostty.org/docs/features) | Win32-specific UX includes DWM dark title bar integration, high-contrast palette switching, IME, drag-and-drop, and native context menus. |

## Maintenance Anchors

- `src/config/Config.zig` — config docs, keybinds, `auto-update` docstrings.
- `src/termio/shell_integration.zig` and `src/config/windows_shell.zig` —
  shell integration and Windows shell detection.
- `src/apprt/win32.zig`, `src/apprt/win32_theme.zig`, and
  `src/apprt/win32_uia/` — Win32 runtime, chrome/input, accessibility.
- `docs/status.md` and `docs/getting-started.md` — user-facing summaries that
  should stay aligned with this matrix.
