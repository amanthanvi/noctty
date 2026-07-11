# Windows

This page collects Windows-specific behavior that differs from upstream
Ghostty's macOS and Linux documentation. For a row-by-row upstream docs
mapping, see [windows-capability-matrix.md](windows-capability-matrix.md).

## Supported Systems

- Windows 10 and Windows 11 on x64 and ARM64.
- Native Win32 application runtime.
- OpenGL 4.3 or newer through WGL.
- `libghostty-vt` remains portable as a library, but this repository does not
  ship macOS, Linux, GTK, Wayland, or X11 app runtimes.

## Install Modes

Current winghostty releases publish signed Windows artifacts for x64 and ARM64:

- `winghostty-<version>-windows-<arch>-setup.exe` for a normal installed app with
  Start menu shortcuts and app identity metadata.
- `winghostty-<version>-windows-<arch>-portable.zip` for portable use without an
  installer.
- `SHA256SUMS-windows-<arch>.txt` for architecture-specific checksum metadata.

Use `x64` or `arm64` for `<arch>`.

Release installers are Authenticode-signed. Windows binaries inside the
portable ZIP are also Authenticode-signed; the ZIP container itself is
checksummed, not Authenticode-signed. Windows SmartScreen may still warn on
first launch while publisher reputation builds. The legacy `SHA256SUMS.txt`
file remains an x64 auto-update compatibility alias.

## Paths

By default, runtime state lives under:

```text
%LOCALAPPDATA%\winghostty\
```

The shared XDG helpers still honor `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, and
`XDG_CACHE_HOME` when they are set on Windows; `%LOCALAPPDATA%` is the fallback
used by the normal packaged app environment.

Important files and directories:

| Path                                           | Purpose                                                                                        |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `%LOCALAPPDATA%\winghostty\config.ghostty`     | User config written on first launch.                                                           |
| `%LOCALAPPDATA%\winghostty\session-state.json` | Window, tab, split, profile, cwd, and title restore state when `window-save-state` is enabled. |
| `%LOCALAPPDATA%\winghostty\crash\`             | Local crash dump directory. Nothing here is uploaded automatically.                            |
| `%LOCALAPPDATA%\winghostty\shell-integration\` | Installed shell-integration payloads and manual fallbacks.                                     |

The portable ZIP carries the bundled resources next to the executable. Do not
move only `winghostty.exe` out of the extracted tree; it needs the packaged
`share` resources for themes, terminfo, shell integration, and other data.

## Shells

The profile picker detects common Windows shells:

- PowerShell Desktop (`powershell.exe`)
- PowerShell 7+ (`pwsh.exe`)
- Command Prompt (`cmd.exe`)
- Git Bash
- WSL when explicitly configured

PowerShell and supported Unix-like shells can use automatic shell integration.
PowerShell integration emits OSC 7 working-directory updates and OSC 133 prompt
markers. `cmd.exe` is a plain fallback shell today and does not provide
automatic prompt, cwd, or command-finish integration.

WSL is supported as an explicitly launched shell:

```ini
command = wsl.exe
```

winghostty does not pick WSL implicitly because `wsl.exe --status` can report a
healthy installation even when launching a session would fail.

## App Identity

Installed builds create Start menu shortcuts with winghostty's AppUserModelID.
That identity is used by Windows for taskbar grouping and Action Center toast
activation. Portable builds run without installer-created shortcuts, so taskbar
and notification identity may be less stable.

If Windows shows a stale icon after upgrading or switching between installed
and portable builds, restart Explorer or clear the icon cache before treating
it as a packaging regression.

## Notifications and Progress

Desktop notifications use WinRT toasts when available and fall back to in-app
banners when Windows notification policy, Focus Assist, app identity, or runtime
availability prevents a toast.

Terminal progress reports are mapped to Windows taskbar progress for the active
surface in each host window. Terminal apps can also set in-terminal progress
state through Ghostty's shared VT/OSC support.

## Windows, Tabs, Splits

winghostty uses a native Win32 host window with:

- tab bar, overflow handling, same-window drag reorder, and exact-pane
  drag-to-split with reversible subtree transfer
- horizontal and vertical splits
- per-monitor DPI handling
- DWM dark title bar integration
- high-contrast palette switching
- IME support
- drag-and-drop of files into the terminal
- native right-click context menus

Session restore persists practical shape: host windows, tabs, split layout,
selected profiles, working directories, and explicit titles. It does not
restore terminal contents or child process state. If the session-state file is
unreadable, winghostty logs the failure and starts with a fresh window; it does
so after attempting to move the invalid state to a timestamped quarantine
sibling. A failed move leaves the source untouched and does not block a clean
window.
Three recent consecutive pre-ready startup failures automatically select an
ephemeral safe mode (built-in config and no session restore); `--safe-mode`
selects it explicitly. User config and quarantined state are never deleted.

`winghostty +diagnostic-bundle` creates a local, inspectable support bundle.
Sensitive terminal, command, environment, cwd, config-value, and dump data are
excluded by default; crash dumps require an explicit opt-in flag.

The universal palette blends configured actions, live tabs, panes, Windows
profiles, and native settings in one fuzzy-ranked, keyboard-accessible list.
Use `>`, `@`, `/`, `~`, or `:` to filter a category. Theme, help, and shell
command-history providers are not exposed yet.

The native Settings window covers Appearance, Terminal, Shell, Keybindings,
and Advanced. It stages edits until Save, patches the target config without
rewriting unrelated text, and reloads the effective configuration. Keybinding
editing still uses the text config and CLI discovery commands. Ownership-safe
native fields support reversible live preview, external-edit conflict
detection, and explicit Keep mine / Use disk resolution.

## Quick Terminal and Global Hotkeys

The quick terminal uses the same `toggle_quick_terminal` action and
`quick-terminal-*` configuration family as Ghostty where the settings map to
Windows. Global keybinds use Win32 `RegisterHotKey` while winghostty is
running. Windows or other applications may reserve hotkeys first; check logs
when a global binding does not register.

`quick-terminal-keyboard-interactivity = exclusive` maps to focused input on
Windows. Global keyboard capture is intentionally not implemented.

## Automation

The local automation surface uses the single-instance IPC path:

```powershell
winghostty +list-windows
winghostty +perform-action new_tab
winghostty +perform-action --surface-id=<surface_id> toggle_fullscreen
```

Automation intentionally rejects terminal-input, arbitrary file helper, and
crash actions. New action variants are disabled for automation until reviewed
and allowlisted.

## Troubleshooting

### SmartScreen

Current release installers and Windows binaries inside the portable ZIP are
Authenticode-signed, but SmartScreen may still warn while publisher reputation
builds. Verify the matching `SHA256SUMS-windows-<arch>.txt` file before running
downloaded artifacts if you want an extra local check.

### Focus Assist and Toasts

If desktop notifications do not appear, check Windows notification settings,
Focus Assist, and whether you are running an installed build with Start menu
shortcuts. In-app banners should still appear for important app notices.

### Global Hotkey Conflicts

Global keybinds can fail when another application or Windows itself owns the
same hotkey. Pick a different trigger or close the conflicting app, then reload
config.

### WSL Launch Failures

Set WSL explicitly with `command = wsl.exe`. If launch still fails, verify the
distribution starts in a normal PowerShell session first.

### OpenGL Driver Issues

winghostty needs OpenGL 4.3 or newer. If the window fails to render or exits
early on older hardware, update GPU drivers before filing a rendering bug.

If startup fails with `LoadLibrary failed with error 126` or the new startup
dialog reports `Win32 error: 126 (ERROR_MOD_NOT_FOUND)` during OpenGL/WGL
initialization, Windows could not load a graphics-driver DLL or one of its
dependencies. On AMD+NVIDIA hybrid-GPU laptops, this can happen while WGL loads
the AMD OpenGL ICD from DriverStore. Update or reinstall the OEM AMD graphics
driver first, then the NVIDIA driver, and try forcing `winghostty.exe` to the
discrete or integrated GPU in Windows Graphics settings. winghostty currently
ships only the OpenGL/WGL renderer on Windows; there is no DirectX or ANGLE
fallback renderer in this build.

### Stale Installed Build

When testing a local build, make sure the `winghostty` found on `PATH` is the
current `zig-out\bin` binary rather than an older Scoop or installer build.
On Windows, `winghostty.com` may be selected before `winghostty.exe` for CLI
invocations.
