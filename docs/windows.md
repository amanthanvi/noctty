# Windows

This page is the reference for Windows-specific behavior: everywhere
winghostty differs from upstream Ghostty's macOS and Linux documentation.
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

- `winghostty-<version>-windows-<arch>-setup.exe`: a normal installed app
  with Start menu shortcuts and app identity metadata.
- `winghostty-<version>-windows-<arch>-portable.zip`: portable use
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
%LOCALAPPDATA%\winghostty\
```

The shared XDG helpers still honor `XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
and `XDG_CACHE_HOME` when they are set on Windows; `%LOCALAPPDATA%` is
the fallback used by the normal packaged app environment.

Important files and directories:

| Path                                           | Purpose                                                                                        |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `%LOCALAPPDATA%\winghostty\config.ghostty`     | User config written on first launch.                                                           |
| `%LOCALAPPDATA%\winghostty\session-state.json` | Window, tab, split, profile, cwd, title, and optional scrollback-snapshot restore state.       |
| `%LOCALAPPDATA%\winghostty\layouts\`           | Named layout JSON files (`apply_layout:<name>` / `--apply-layout=`).                           |
| `%LOCALAPPDATA%\winghostty\crash\`             | Local crash dump directory. Nothing here is uploaded automatically.                            |
| `%LOCALAPPDATA%\winghostty\shell-integration\` | Installed shell-integration payloads and manual fallbacks.                                     |

The portable ZIP carries the bundled resources next to the executable.
Don't move only `winghostty.exe` out of the extracted tree; it needs the
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

`cmd.exe` is no longer a plain fallback: winghostty sets `PROMPT` so
the next prompt emits OSC 133 A/B and OSC 9;9 (cwd). Command-start (C)
and exit-code (D) marks are added when [Clink](https://chrisant996.github.io/clink/)
is on `PATH`. Jump-to-prompt, copy-last-output, and re-run-last-command
use those marks; see [Prompt-mark navigation](#prompt-mark-navigation).

`utf8-console = auto|always|never` (default `auto`) applies a UTF-8
console preamble so Nerd Font / oh-my-posh glyphs survive `cmd` and
Windows PowerShell 5.1. `auto` skips forcing UTF-8 when the active
console output code page is a legacy CJK ANSI page (932, 936, 949,
950), because that can break existing OEM-encoded tools.

WSL shows up in the picker, but it never becomes the default shell
implicitly, because `wsl.exe --status` can report a healthy installation
even when launching a session would fail. To make it your default, opt
in explicitly:

```ini
command = wsl.exe
```

## OS entry points

Taskbar jump lists show recent working directories reported by shell
integration (OSC 7 / OSC 9;9) plus named layouts. Clicking a directory
opens a new window via `--working-directory`; a layout uses
`--apply-layout=`.

The installer and portable first-run registration add Explorer
**Open winghostty here** on folders and folder backgrounds. Portable
builds write HKCU verbs pointing at the current `winghostty.exe`;
uninstall / moving the portable folder leaves those verbs stale until
the next launch from the new path. Win11 `IExplorerCommand` COM is
the remaining C13 slice; classic verbs ship today.

Named layouts live in `%LOCALAPPDATA%\winghostty\layouts\<name>.json`
using the session-state schema. Apply with `apply_layout:<name>` or
`--apply-layout=<name>`.

## Elevation

Elevated winghostty is a **separate process** launched with the
`runas` verb (palette: Open Elevated Window). Mixed-elevation tabs
in one window are out. Session restore never relaunches elevated
windows; re-open them explicitly. The title is prefixed
`[Administrator]` when the process is elevated.

## SSH hosts

winghostty parses `%USERPROFILE%\.ssh\config` `Host` lines (skips
wildcards). Launch with the system client:

```powershell
winghostty -e ssh jump
```

No bundled SSH client and no credential vault.

## Power

On battery, unfocused panes skip extra renderer wakes (C02). Focused
and AC-powered sessions stay on the normal path. Idle wattage belongs
in [windows-benchmarks.md](windows-benchmarks.md) once a baseline exists.

## Prompt-mark navigation

With shell integration loaded, these actions are in the command palette
and (for jump) on the default keybinds:

| Action | Default bind | What it does |
| --- | --- | --- |
| Jump to previous prompt | `Ctrl+Shift+PageUp` | Scroll to the previous OSC 133 prompt |
| Jump to next prompt | `Ctrl+Shift+PageDown` | Scroll to the next OSC 133 prompt |
| Copy last command output | palette | Copies text between the last two prompt marks |
| Re-run last command | palette | Sends the first line after the previous prompt, then Enter |

These never intercept the shell's own editor (no Warp-style input
takeover). They only read marks the shell already emitted.

## GPU floor

winghostty requires **OpenGL 4.3+ via WGL** for terminal content. There
is no DirectX or ANGLE fallback in this build. Corporate VMs, RDP
sessions, and older iGPUs that only expose a software or 3.x ICD will
not get a blank window: startup shows a dialog that names the failed
step, the Win32 error, and the 4.3 requirement.

What to try:

1. Update the OEM GPU driver (AMD then NVIDIA on hybrid laptops).
2. In Windows Graphics settings, pin `winghostty.exe` to the discrete
   or integrated GPU and retry.
3. For RDP / nested VMs, enable GPU remoting or run on a session with a
   real OpenGL 4.3 ICD. RemoteFX / basic RDP WARP often cannot satisfy
   the floor.

Chrome still paints with D3D11/DirectComposition even when the terminal
renderer is the one that failed; that does not replace the GL path.

## Paste-path security

Clipboard paste and Explorer / browser drag-drop share one confirm
path:

1. Core `clipboard-paste-protection` (newlines and bracketed-paste-end).
2. The Win32 classifier in `src/apprt/win32_paste_protection.zig`
   (control characters, shell metacharacters including `$var` / `%VAR%`,
   mixed URL content).

Unsafe payloads open the non-modal confirm overlay; they are never
routed through `textCallback` (that path treats newlines as typed
intent). This is the fork's coverage of upstream CVE-2026-26982 plus
the Win32-only drop surfaces that AFL++ does not exercise.

## App identity

Installed builds create Start menu shortcuts with winghostty's
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

winghostty uses a native Win32 host window with:

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
explicit titles. Set `window-save-scrollback-lines = N` to also persist
the last N lines per pane as a marked snapshot (not a live session).
Child processes are not restored.

If the session-state file is unreadable, winghostty moves it aside to a
sibling named after the original with a `.corrupt` suffix, logs the
failure, and starts with a fresh window. A numeric suffix is added
(`.corrupt.1`, `.corrupt.2`, and so on) when an earlier quarantine file
is already there, so nothing is overwritten. If the move fails, the
original file is left untouched.

Three consecutive pre-ready startup failures automatically select an
ephemeral safe mode: built-in config, no session restore. You can also
pick it explicitly for one launch:

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
every 24 hours and never replaces binaries silently. In `check` mode it
opens the release page when a newer stable version exists.

`auto-update = download` goes further. It downloads only stable Windows
installer releases that ship architecture-specific SHA256 metadata, then
verifies the installer's SHA-256 against that manifest and requires a
valid Windows Authenticode signature before staging the installer under
the local winghostty state directory. The signature check is not generic:
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
apply plans the sibling `.apply-new` / `.apply-old` swap and quits so
the current exe handle can be released; extracting the zip into
`.apply-new` is the remaining helper slice. Re-point the updater API
with `WINGHOSTTY_UPDATE_API_BASE` (C31). See also
[windows-signing.md](windows-signing.md) and [trust.md](trust.md).

The updater is also the only outbound network call the app makes; there
is no telemetry and no analytics.

## Quick terminal and global hotkeys

The quick terminal uses the same `toggle_quick_terminal` action and
`quick-terminal-*` configuration family as Ghostty where the settings map
to Windows. Global keybinds use Win32 `RegisterHotKey` while winghostty
is running. Windows or other applications may reserve hotkeys first;
check logs when a global binding does not register.

`quick-terminal-keyboard-interactivity = exclusive` maps to focused input
on Windows. Global keyboard capture is intentionally not implemented.

## Default terminal

winghostty advertises a COM LocalServer32 class for `ITerminalHandoff`
(`--terminal-handoff`) but does **not** write `DelegationTerminal`.
Becoming the OS default before pipe-attach lands would open empty
windows. Keep Windows Terminal (or conhost) as the default until that
slice ships. See [windows-conpty.md](windows-conpty.md).

## Automation

See [windows-automation.md](windows-automation.md) for the staged verb
set. The short version:

List windows, tabs, and panes:

```powershell
winghostty +list-windows
```

The JSON schema is `winghostty.windows.v2`. It exposes local window, tab,
and pane IDs, focus/active state, and structural counts only. It never
includes terminal text, shell input, working directories, or file paths.

Invoke a keybinding action on the focused surface, or on a specific pane
from `+list-windows`:

```powershell
winghostty +perform-action new_tab
winghostty +perform-action --surface-id=<surface_id> toggle_fullscreen
```

Actions use the same names as `keybind` values. `--surface-id` is only
valid for surface-scoped actions; app-scoped actions such as `quit`
always target the app. The running instance rejects terminal-input and
arbitrary file helper actions (`text`, `csi`, `esc`,
`paste_from_clipboard`, `write_screen_file`, and `crash`), and new
keybinding action variants stay disabled for automation until they are
reviewed and allowlisted.

## Crash reports and diagnostics

winghostty keeps a local crash directory and never uploads anything from
it:

```text
%LOCALAPPDATA%\winghostty\crash
```

On Windows the Sentry initialization path is a no-op. Instead, winghostty
installs a local unhandled-exception filter that writes `.dmp` minidumps
for process-level crash exceptions. Some hard-abort paths may still
terminate before Windows can produce a dump. Read whatever is there with:

```powershell
winghostty +crash-report
```

Dumps can contain sensitive memory from the crashed process. Review them
before sharing.

For a local-only, inspectable support bundle:

```powershell
winghostty +diagnostic-bundle --output=winghostty-diagnostics
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

See [GPU floor](#gpu-floor). If the window fails to render or exits
early on older hardware, update GPU drivers before filing a rendering
bug.

If startup fails with `LoadLibrary failed with error 126` or the startup
dialog reports `Win32 error: 126 (ERROR_MOD_NOT_FOUND)` during OpenGL/WGL
initialization, Windows could not load a graphics-driver DLL or one of
its dependencies. This shows up most often on AMD+NVIDIA hybrid-GPU
laptops while WGL loads the AMD OpenGL ICD from DriverStore. Try, in
order:

1. Update or reinstall the OEM AMD graphics driver, then the NVIDIA
   driver.
2. Force `winghostty.exe` to the discrete or integrated GPU in Windows
   Graphics settings.

winghostty currently ships only the OpenGL/WGL renderer on Windows; there
is no DirectX or ANGLE fallback renderer in this build.

### Stale installed build

When testing a local build, make sure the `winghostty` you invoke is the
current `zig-out\bin` binary rather than an older Scoop shim or a
manually added install directory earlier on `PATH`. On Windows,
`winghostty.com` may be selected before `winghostty.exe` for CLI
invocations.

## Benchmarks

Published Windows numbers live in
[windows-benchmarks.md](windows-benchmarks.md). The harness is
`scripts/bench-windows.ps1`. PRODUCT.md budgets stay provisional until
the first same-machine baseline against Windows Terminal, Alacritty,
Tabby, and Wave.
