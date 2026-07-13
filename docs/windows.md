# Windows

This page is the reference for Windows-specific behavior — everywhere
winghostty differs from upstream Ghostty's macOS and Linux documentation. For
a row-by-row mapping against upstream docs, see
[windows-capability-matrix.md](windows-capability-matrix.md). For VT protocol
coverage validated on the Win32 runtime, see
[windows-vt-conformance.md](windows-vt-conformance.md).

## Supported Systems

- Windows 10 and Windows 11 on x64 and ARM64.
- Native Win32 application runtime.
- OpenGL 4.3 or newer through WGL.
- `libghostty-vt` stays portable as a library, but this repository doesn't
  ship macOS, Linux, GTK, Wayland, or X11 app runtimes.

## Install Modes

Each release publishes signed Windows artifacts for x64 and arm64:

- `winghostty-<version>-windows-<arch>-setup.exe` — a normal installed app
  with Start menu shortcuts and app identity metadata.
- `winghostty-<version>-windows-<arch>-portable.zip` — portable use without
  an installer.
- `SHA256SUMS-windows-<arch>.txt` — architecture-specific checksum metadata.

Release installers and the Windows binaries inside the portable ZIP are
Authenticode-signed; the ZIP container itself is checksummed, not
Authenticode-signed. The legacy `SHA256SUMS.txt` file remains an x64
auto-update compatibility alias.

For the download-and-install walkthrough, including SmartScreen guidance, see
[getting-started.md](getting-started.md).

## Paths

By default, runtime state lives under:

```text
%LOCALAPPDATA%\winghostty\
```

The shared XDG helpers still honor `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, and
`XDG_CACHE_HOME` when they are set on Windows; `%LOCALAPPDATA%` is the
fallback used by the normal packaged app environment.

Important files and directories:

| Path                                           | Purpose                                                                                        |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `%LOCALAPPDATA%\winghostty\config.ghostty`     | User config written on first launch.                                                           |
| `%LOCALAPPDATA%\winghostty\session-state.json` | Window, tab, split, profile, cwd, and title restore state when `window-save-state` is enabled. |
| `%LOCALAPPDATA%\winghostty\crash\`             | Local crash dump directory. Nothing here is uploaded automatically.                            |
| `%LOCALAPPDATA%\winghostty\shell-integration\` | Installed shell-integration payloads and manual fallbacks.                                     |

The portable ZIP carries the bundled resources next to the executable. Don't
move only `winghostty.exe` out of the extracted tree; it needs the packaged
`share` resources for themes, terminfo, shell integration, and other data.

## Shells

The profile picker detects common Windows shells:

- PowerShell Desktop (`powershell.exe`)
- PowerShell 7+ (`pwsh.exe`)
- Command Prompt (`cmd.exe`)
- Git Bash
- WSL, when you configure it explicitly

PowerShell and supported Unix-like shells get automatic shell integration.
PowerShell integration emits OSC 7 working-directory updates and OSC 133
prompt markers. `cmd.exe` is a plain fallback shell today — no automatic
prompt, cwd, or command-finish integration.

WSL never becomes the default shell implicitly, because `wsl.exe --status`
can report a healthy installation even when launching a session would fail.
Opt in explicitly:

```ini
command = wsl.exe
```

## App Identity

Installed builds create Start menu shortcuts with winghostty's
AppUserModelID. Windows uses that identity for taskbar grouping and Action
Center toast activation. Portable builds run without installer-created
shortcuts, so taskbar and notification identity may be less stable.

If Windows shows a stale icon after upgrading or switching between installed
and portable builds, restart Explorer or clear the icon cache before treating
it as a packaging regression.

## Notifications and Progress

Desktop notifications use WinRT toasts when available and fall back to in-app
banners when Windows notification policy, Focus Assist, app identity, or
runtime availability prevents a toast.

Terminal progress reports are mapped to Windows taskbar progress for the
active surface in each host window. Terminal apps can also set in-terminal
progress state through Ghostty's shared VT/OSC support.

## Windows, Tabs, and Splits

winghostty uses a native Win32 host window with:

- a tab bar with overflow handling, same-window drag reorder, and exact-pane
  drag-to-split with reversible subtree transfer
- horizontal and vertical splits
- per-monitor DPI handling
- DWM dark title bar integration
- high-contrast palette switching
- IME support
- drag-and-drop of files into the terminal
- native right-click context menus

The universal palette puts actions, live tabs, panes, Windows profiles, and
native settings behind one fuzzy-ranked, keyboard-driven list; use `>`, `@`,
`/`, `~`, or `:` to filter a category. The native Settings window stages
edits until Save and patches your config without rewriting unrelated text.
The full feature detail for both lives in the
[capability matrix notes](windows-capability-matrix.md#notes).

## Session Restore and Recovery

Session restore persists the practical shape of your workspace: host windows,
tabs, split layout, selected profiles, working directories, and explicit
titles. It doesn't restore terminal contents or child process state.

If the session-state file is unreadable, winghostty moves it aside to a
timestamped quarantine sibling, logs the failure, and starts with a fresh
window. If that move fails, the original file is left untouched — an
unreadable state file never blocks a clean start, and nothing is deleted.

Three consecutive pre-ready startup failures automatically select an
ephemeral safe mode: built-in config, no session restore. You can also pick
it explicitly for one launch:

```powershell
winghostty --safe-mode
```

Safe mode never overwrites your config or quarantined state.

## Updates

Enable update checks in your config:

```ini
auto-update = check
```

The updater calls
`api.github.com/repos/amanthanvi/winghostty/releases/latest` at most once
every 24 hours and never replaces binaries silently. In `check` mode it opens
the release page when a newer stable version exists.

`auto-update = download` goes further: it downloads only stable Windows
installer releases that ship architecture-specific SHA256 metadata, verifies
the installer's SHA-256 against that manifest, requires a valid Windows
Authenticode signature, and stages the installer under the local winghostty
state directory. Unsigned installers fail that verification and are not
staged.

For installer-managed installs, the update notice can launch the verified
staged installer. Applying an update is always user-initiated: it re-verifies
the staged installer, records apply intent, launches the installer elevated
(UAC may prompt), and exits the app. Portable ZIP auto-apply is not
implemented yet.

The updater is also the only outbound network call the app makes — there is
no telemetry and no analytics.

## Quick Terminal and Global Hotkeys

The quick terminal uses the same `toggle_quick_terminal` action and
`quick-terminal-*` configuration family as Ghostty where the settings map to
Windows. Global keybinds use Win32 `RegisterHotKey` while winghostty is
running. Windows or other applications may reserve hotkeys first; check logs
when a global binding does not register.

`quick-terminal-keyboard-interactivity = exclusive` maps to focused input on
Windows. Global keyboard capture is intentionally not implemented.

## Automation

winghostty exposes a local Windows automation surface over the same
single-instance IPC path used by `+new-window`.

List windows, tabs, and panes:

```powershell
winghostty +list-windows
```

The JSON schema is `winghostty.windows.v2`. It exposes local window, tab, and
pane IDs, focus/active state, and structural counts only — never terminal
text, shell input, working directories, or file paths.

Invoke a keybinding action on the focused surface, or on a specific pane from
`+list-windows`:

```powershell
winghostty +perform-action new_tab
winghostty +perform-action --surface-id=<surface_id> toggle_fullscreen
```

Actions use the same names as `keybind` values. `--surface-id` is only valid
for surface-scoped actions; app-scoped actions such as `quit` always target
the app. The running instance rejects terminal-input and arbitrary file
helper actions (`text`, `csi`, `esc`, `paste_from_clipboard`,
`write_screen_file`, and `crash`), and new keybinding action variants stay
disabled for automation until they are reviewed and allowlisted.

## Crash Reports and Diagnostics

winghostty keeps a local crash directory and never uploads anything from it:

```text
%LOCALAPPDATA%\winghostty\crash
```

On Windows the Sentry initialization path is a no-op. Instead, winghostty
installs a local unhandled-exception filter that writes `.dmp` minidumps for
process-level crash exceptions. Some hard-abort paths may still terminate
before Windows can produce a dump. Read whatever is there with:

```powershell
winghostty +crash-report
```

Dumps can contain sensitive memory from the crashed process — review them
before sharing.

For a local-only, inspectable support bundle:

```powershell
winghostty +diagnostic-bundle --output=winghostty-diagnostics
```

Terminal content, commands, environment, working directories, and config
values are excluded by default. Crash dumps are excluded too unless you pass
the explicit `--include-crash-dumps` flag.

## Troubleshooting

### SmartScreen

Release installers and the Windows binaries inside the portable ZIP are
Authenticode-signed, but SmartScreen may still warn while publisher
reputation builds. For an extra local check, verify downloads against the
matching `SHA256SUMS-windows-<arch>.txt` file before running them.

### Focus Assist and Toasts

If desktop notifications don't appear, check Windows notification settings,
Focus Assist, and whether you're running an installed build with Start menu
shortcuts. In-app banners should still appear for important app notices.

### Global Hotkey Conflicts

Global keybinds can fail when another application or Windows itself owns the
same hotkey. Pick a different trigger or close the conflicting app, then
reload config.

### WSL Launch Failures

Set WSL explicitly with `command = wsl.exe`. If launch still fails, verify
the distribution starts in a normal PowerShell session first.

### OpenGL Driver Issues

winghostty needs OpenGL 4.3 or newer. If the window fails to render or exits
early on older hardware, update GPU drivers before filing a rendering bug.

If startup fails with `LoadLibrary failed with error 126` or the startup
dialog reports `Win32 error: 126 (ERROR_MOD_NOT_FOUND)` during OpenGL/WGL
initialization, Windows could not load a graphics-driver DLL or one of its
dependencies. This shows up most often on AMD+NVIDIA hybrid-GPU laptops while
WGL loads the AMD OpenGL ICD from DriverStore. Try, in order:

1. Update or reinstall the OEM AMD graphics driver, then the NVIDIA driver.
2. Force `winghostty.exe` to the discrete or integrated GPU in Windows
   Graphics settings.

winghostty currently ships only the OpenGL/WGL renderer on Windows; there is
no DirectX or ANGLE fallback renderer in this build.

### Stale Installed Build

When testing a local build, make sure the `winghostty` found on `PATH` is the
current `zig-out\bin` binary rather than an older Scoop or installer build.
On Windows, `winghostty.com` may be selected before `winghostty.exe` for CLI
invocations.
