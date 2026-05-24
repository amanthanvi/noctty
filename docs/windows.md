# Windows

This page collects Windows-specific behavior that differs from upstream
Ghostty's macOS and Linux documentation. For a row-by-row upstream docs
mapping, see [windows-capability-matrix.md](windows-capability-matrix.md).

## Supported Systems

- Windows 10 and Windows 11 on x64.
- Native Win32 application runtime.
- OpenGL 4.3 or newer through WGL.
- `libghostty-vt` remains portable as a library, but this repository does not
  ship macOS, Linux, GTK, Wayland, or X11 app runtimes.

## Install Modes

winghostty publishes two Windows artifacts:

- `winghostty-<version>-windows-x64-setup.exe` for a normal installed app with
  Start menu shortcuts and app identity metadata.
- `winghostty-<version>-windows-x64-portable.zip` for portable use without an
  installer.

Releases are currently unsigned. Windows SmartScreen may warn on first launch;
click **More info** and **Run anyway** if you trust the downloaded release.
Unsigned installers are not eligible for `auto-update = download` staging
because staging requires a valid Authenticode signature.

## Paths

Runtime state lives under:

```text
%LOCALAPPDATA%\winghostty\
```

Important files and directories:

| Path | Purpose |
| --- | --- |
| `%LOCALAPPDATA%\winghostty\config.ghostty` | User config written on first launch. |
| `%LOCALAPPDATA%\winghostty\session-state.json` | Window, tab, split, profile, cwd, and title restore state when `window-save-state` is enabled. |
| `%LOCALAPPDATA%\winghostty\crash\` | Local crash dump directory. Nothing here is uploaded automatically. |
| `%LOCALAPPDATA%\winghostty\shell-integration\` | Installed shell-integration payloads and manual fallbacks. |

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

- tab bar, overflow handling, and drag reorder
- horizontal and vertical splits
- per-monitor DPI handling
- DWM dark title bar integration
- high-contrast palette switching
- IME support
- drag-and-drop of files into the terminal
- native right-click context menus

Session restore persists practical shape: host windows, tabs, split layout,
selected profiles, working directories, and explicit titles. It does not
restore terminal contents or child process state.

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

Current releases are unsigned. SmartScreen warnings are expected until code
signing lands. Verify `SHA256SUMS.txt` before running downloaded artifacts if
you want an extra local check.

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

### Stale Installed Build

When testing a local build, make sure the `winghostty` found on `PATH` is the
current `zig-out\bin` binary rather than an older Scoop or installer build.
On Windows, `winghostty.com` may be selected before `winghostty.exe` for CLI
invocations.
