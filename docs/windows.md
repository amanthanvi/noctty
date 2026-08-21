# Windows

This page is the reference for Windows-specific behavior: everywhere
noctty differs from upstream Ghostty's macOS and Linux documentation.
For a row-by-row mapping against upstream docs, see
[windows-capability-matrix.md](windows-capability-matrix.md). For VT
protocol coverage validated on the Win32 runtime, see
[windows-vt-conformance.md](windows-vt-conformance.md).

## Supported systems

- Windows 10 and Windows 11 on x64 and ARM64.
- Native Win32 application runtime.
- OpenGL 4.3 or newer through WGL.
- `libghostty-vt` stays portable as a library, but this repository
  doesn't ship macOS, Linux, GTK, Wayland, or X11 app runtimes.

## Install modes

Each release publishes signed Windows artifacts for x64 and ARM64:

- `noctty-<version>-windows-<arch>-setup.exe`: a normal installed app
  with Start menu shortcuts and app identity metadata.
- `noctty-<version>-windows-<arch>-portable.zip`: portable use
  without an installer.
- `SHA256SUMS-windows-<arch>.txt`: architecture-specific checksums.

The installer and the binaries inside the portable ZIP are
Authenticode-signed with a self-signed certificate; the ZIP container
itself is checksummed, not signed.
The legacy `SHA256SUMS.txt` file remains an x64 auto-update compatibility
alias.

For the download-and-install walkthrough, including what the SmartScreen
warning means, see [getting-started.md](getting-started.md).

## Paths

By default, runtime state lives under:

```text
%LOCALAPPDATA%\noctty\
```

The shared XDG helpers still honor `XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
and `XDG_CACHE_HOME` when they are set on Windows; `%LOCALAPPDATA%` is
the fallback used by the normal packaged app environment.

Important files and directories:

| Path                                           | Purpose                                                                                        |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `%LOCALAPPDATA%\noctty\config.ghostty`     | User config written on first launch.                                                           |
| `%LOCALAPPDATA%\noctty\session-state.json` | Window, tab, split, profile, cwd, and title restore state when `window-save-state` is enabled. |
| `%LOCALAPPDATA%\noctty\crash\`             | Local crash dump directory. Nothing here is uploaded automatically.                            |
| `%LOCALAPPDATA%\noctty\shell-integration\` | Installed shell-integration payloads and manual fallbacks.                                     |

The portable ZIP carries the bundled resources next to the executable.
Don't move only `noctty.exe` out of the extracted tree; it needs the
packaged `share` resources for themes, terminfo, shell integration, and
other data.

## Shells

The profile picker detects common Windows shells:

- PowerShell 7+ (`pwsh.exe`)
- Windows PowerShell (`powershell.exe`)
- Command Prompt (`cmd.exe`)
- Git Bash
- WSL distributions, listed automatically when `wsl.exe` is installed
  and responsive

Shell integration is automatic for PowerShell and directly launched
Unix-like shells such as Git Bash; WSL sessions manage their own
integration inside the distribution. PowerShell integration emits OSC 7
working-directory updates and OSC 133 prompt markers.

For `cmd.exe`, noctty wraps the inherited `PROMPT` value, falling back to
cmd's `$P$G` default when it is unset. A `PROMPT` supplied through noctty's
`env = PROMPT=...` configuration is applied afterward and intentionally
replaces this wrapper. The wrapper emits OSC 133 A/B prompt marks and OSC 9;9
working-directory reports. If `clink.bat` or `clink_x64.exe` is found on
`PATH` or under `%LOCALAPPDATA%\clink`, noctty prepends its shipped Lua
directory to `CLINK_PATH`. This only makes the script discoverable after Clink
is active through autorun, `clink inject`, or an explicit Clink launch; noctty
does not inject or launch Clink. When loaded, the script adds OSC 133 C/D
command marks and the exit code before the next prompt. `os.geterrorlevel()`
reports a truthful exit code only while Clink's `cmd.get_errorlevel` setting is
enabled (the default). Without the loaded Clink script, prompt navigation and
cwd reporting still work, but there are no command-finish marks or exit codes.

With OSC 133 shell integration active, these command-palette actions and
Windows defaults are available:

- `jump_to_prompt:-1` / `jump_to_prompt:1` — previous / next prompt,
  `Ctrl+Shift+PageUp` / `Ctrl+Shift+PageDown`.
- `copy_last_command_output` — copy the most recent completed command's output,
  `Ctrl+Shift+Y`. This requires OSC 133;C and OSC 133;D command-output
  boundaries.
- `rerun_last_command` — run the most recent recoverable single-line command
  again, `Ctrl+Shift+R`. This requires shell integration that emits OSC 133;B
  and OSC 133;C command-input boundaries; noctty does not read or modify the
  shell's line editor.

`utf8-console` controls UTF-8 setup for bare interactive `cmd.exe` launches,
Windows PowerShell 5.1, and PowerShell 7 (`pwsh`) sessions. `auto` is the default
and enables UTF-8 unless the machine ANSI or OEM code page is 932 (Shift-JIS),
936 (GBK), 949 (EUC-KR), or 950 (Big5); `always` enables it despite that
legacy-CJK guard, and `never` leaves the shell encoding unchanged. The Command
Prompt preamble applies only to a bare `cmd.exe` launch; `/c`, `/k`, and any
other command tail are left unchanged. The cmd preamble is a no-op if the live
console already uses code page 65001; PowerShell checks the live input and output
code pages before changing them. This option does not apply to WSL or Git Bash.

WSL shows up in the picker, but it never becomes the default shell
implicitly, because `wsl.exe --status` can report a healthy installation
even when launching a session would fail. To make it your default, opt
in explicitly:

```ini
command = wsl.exe
```

## App identity

Installed builds create Start menu shortcuts with noctty's
AppUserModelID. Windows uses that identity for taskbar grouping and
Action Center toast activation. Portable builds run without
installer-created shortcuts, so taskbar and notification identity may be
less stable.

If Windows shows a stale icon after upgrading or switching between
installed and portable builds, restart Explorer or clear the icon cache
before assuming the build is broken.

## Notifications and progress

Desktop notifications use WinRT toasts when available and fall back to
in-app banners when Windows notification policy, Focus Assist, app
identity, or runtime availability prevents a toast.

Terminal progress reports are mapped to Windows taskbar progress for the
active surface in each host window. Terminal apps can also set
in-terminal progress state through Ghostty's shared VT/OSC support.

## Windows, tabs, and splits

noctty uses a native Win32 host window with:

- a tab bar with overflow handling, same-window drag reorder, and
  exact-pane drag-to-split with reversible subtree transfer
- horizontal and vertical splits
- per-monitor DPI handling
- DWM dark title bar integration
- high-contrast palette switching
- IME support
- drag-and-drop of files into the terminal
- native right-click context menus

The universal palette puts actions, live tabs, panes, Windows profiles,
and native settings behind one fuzzy-ranked, keyboard-driven list. Type
a prefix to filter one category: `>` actions, `@` tabs, `/` panes, `~`
profiles, `:` settings, `%` themes, `!` recent commands, or `?` for
help. The native Settings
window stages edits until Save and patches your config without rewriting
unrelated text. The full feature detail for both lives in the
[capability matrix notes](windows-capability-matrix.md#notes).

## Session restore and recovery

Session restore persists the practical shape of your workspace: host
windows, tabs, split layout, selected profiles, working directories, and
explicit titles. It doesn't restore terminal contents or child process
state.

If the session-state file is unreadable, noctty moves it aside to a
sibling named after the original with a `.corrupt` suffix, logs the
failure, and starts with a fresh window. A numeric suffix is added
(`.corrupt.1`, `.corrupt.2`, and so on) when an earlier quarantine file
is already there, so nothing is overwritten. If the move fails, the
original file is left untouched.

Three consecutive pre-ready startup failures automatically select an
ephemeral safe mode: built-in config, no session restore. You can also
pick it explicitly for one launch:

```powershell
noctty --safe-mode
```

Safe mode never overwrites your config or quarantined state.

## Updates

Enable update checks in your config:

```ini
auto-update = check
```

The updater calls
`api.github.com/repos/amanthanvi/noctty/releases/latest` at most once
every 24 hours and never replaces binaries silently. In `check` mode it
opens the release page when a newer stable version exists.

`auto-update = download` goes further. It downloads only stable Windows
installer releases that ship architecture-specific SHA256 metadata, then
verifies the installer's SHA-256 against that manifest and requires a
valid Windows Authenticode signature before staging the installer under
the local noctty state directory. The signature check is not generic:
the signer's public key must match a SHA-256 SPKI pin compiled into the
app, so an installer signed by any other key is rejected even when its
signature is otherwise valid. Unsigned installers fail that verification
too, and neither is staged. See
[ADR 0005](adr/0005-pin-updater-publisher-public-keys.md) for the pinning
and key-rotation rules.

For installer-managed installs, the update notice can launch the verified
staged installer. Applying an update is always user-initiated: it
re-verifies the staged installer, records apply intent, launches the
installer elevated (UAC may prompt), and exits the app. Portable ZIP
auto-apply is not implemented yet.

The updater is also the only outbound network call the app makes; there
is no telemetry and no analytics.

## Quick terminal and global hotkeys

The quick terminal uses the same `toggle_quick_terminal` action and
`quick-terminal-*` configuration family as Ghostty where the settings map
to Windows. Global keybinds use Win32 `RegisterHotKey` while noctty
is running. Windows or other applications may reserve hotkeys first;
check logs when a global binding does not register.

`quick-terminal-keyboard-interactivity = exclusive` maps to focused input
on Windows. Global keyboard capture is intentionally not implemented.

## Automation

noctty exposes a local Windows automation surface over the same
single-instance IPC path used by `+new-window`.

List windows, tabs, and panes:

```powershell
noctty +list-windows
```

The JSON schema is `noctty.windows.v2`. It exposes local window, tab,
and pane IDs, focus/active state, and structural counts only. It never
includes terminal text, shell input, working directories, or file paths.

Invoke a keybinding action on the focused surface, or on a specific pane
from `+list-windows`:

```powershell
noctty +perform-action new_tab
noctty +perform-action --surface-id=<surface_id> toggle_fullscreen
```

Actions use the same names as `keybind` values. `--surface-id` is only
valid for surface-scoped actions; app-scoped actions such as `quit`
always target the app. The running instance rejects terminal-input and
arbitrary file helper actions (`text`, `csi`, `esc`,
`paste_from_clipboard`, `write_screen_file`, and `crash`), and new
keybinding action variants stay disabled for automation until they are
reviewed and allowlisted.

## Crash reports and diagnostics

noctty keeps a local crash directory and never uploads anything from
it:

```text
%LOCALAPPDATA%\noctty\crash
```

On Windows the Sentry initialization path is a no-op. Instead, noctty
installs a local unhandled-exception filter that writes `.dmp` minidumps
for process-level crash exceptions. Some hard-abort paths may still
terminate before Windows can produce a dump. Read whatever is there with:

```powershell
noctty +crash-report
```

Dumps can contain sensitive memory from the crashed process. Review them
before sharing.

For a local-only, inspectable support bundle:

```powershell
noctty +diagnostic-bundle --output=noctty-diagnostics
```

Terminal content, commands, environment, working directories, and config
values are excluded by default. Crash dumps are excluded too unless you
pass the explicit `--include-crash-dumps` flag.

## Troubleshooting

### SmartScreen

SmartScreen warns on release downloads because the current signing
certificate is self-signed and so carries no publisher reputation. What
the warning means, and how to verify a download against its checksum
file first, is covered in
[getting-started.md](getting-started.md#about-the-smartscreen-warning).

### Focus Assist and toasts

If desktop notifications don't appear, check Windows notification
settings, Focus Assist, and whether you're running an installed build
with Start menu shortcuts. In-app banners should still appear for
important app notices.

### Global hotkey conflicts

Global keybinds can fail when another application or Windows itself owns
the same hotkey. Pick a different trigger or close the conflicting app,
then reload config.

### WSL launch failures

Set WSL explicitly with `command = wsl.exe`. If launch still fails,
verify the distribution starts in a normal PowerShell session first.

### OpenGL driver issues

noctty needs OpenGL 4.3 or newer. If the window fails to render or
exits early on older hardware, update GPU drivers before filing a
rendering bug.

If startup fails with `LoadLibrary failed with error 126` or the startup
dialog reports `Win32 error: 126 (ERROR_MOD_NOT_FOUND)` during OpenGL/WGL
initialization, Windows could not load a graphics-driver DLL or one of
its dependencies. This shows up most often on AMD+NVIDIA hybrid-GPU
laptops while WGL loads the AMD OpenGL ICD from DriverStore. Try, in
order:

1. Update or reinstall the OEM AMD graphics driver, then the NVIDIA
   driver.
2. Force `noctty.exe` to the discrete or integrated GPU in Windows
   Graphics settings.

noctty currently ships only the OpenGL/WGL renderer on Windows; there
is no DirectX or ANGLE fallback renderer in this build.

### Stale installed build

When testing a local build, make sure the `noctty` you invoke is the
current `zig-out\bin` binary rather than an older Scoop shim or a
manually added install directory earlier on `PATH`. On Windows, a
`noctty.com` executable may be selected before `noctty.exe` for CLI
invocations, because `.com` ranks before `.exe` in `PATHEXT`.
