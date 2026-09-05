# Windows

Where noctty differs from upstream Ghostty's macOS and Linux documentation.
For a row-by-row mapping against upstream docs, see
[windows-capability-matrix.md](windows-capability-matrix.md). For VT
protocol coverage validated on the Win32 runtime, see
[windows-vt-conformance.md](windows-vt-conformance.md).

## Supported systems

- Windows 10 version 1809 (build 17763) or newer, and Windows 11, on x64
  and ARM64. 1809 is a hard floor: `CreatePseudoConsole` is a static
  `kernel32` import, so an earlier build refuses to start the process rather
  than degrading.
- Native Win32 application runtime.
- OpenGL 4.3 or newer through WGL.
- `libghostty-vt` stays portable as a library. This repository does not
  ship macOS, Linux, GTK, Wayland, or X11 app runtimes.

## Install modes

Each release publishes signed Windows artifacts for x64 and ARM64:

- `noctty-<version>-windows-<arch>-setup.exe`: installed app with Start
  menu shortcuts and app identity metadata.
- `noctty-<version>-windows-<arch>-portable.zip`: portable use without an
  installer.
- `noctty-<version>-windows-<arch>-portable.manifest.ps1`: signed hashes
  for the exact portable payload.
- `SHA256SUMS-windows-<arch>.txt`: architecture-specific checksums.

The installer, portable manifest, and binaries inside the portable ZIP are
Authenticode-signed with a self-signed certificate. The ZIP container is
checksummed and bound to the canonical release workflow by GitHub build
provenance. The legacy `SHA256SUMS.txt` file remains an x64 auto-update
compatibility alias.

A Chocolatey package (`noctty`) is built by the release workflow but has not
been published yet, so `choco install noctty` does not work today. It will
after the first push clears chocolatey.org moderation.

[getting-started.md](getting-started.md) covers download and install,
including the SmartScreen warning. [verify-release.md](verify-release.md)
covers checksum, provenance, and signature checks.

## Paths

Runtime state lives under `%LOCALAPPDATA%\noctty\` by default. The shared
XDG helpers still honor `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, and
`XDG_CACHE_HOME` when set on Windows; `%LOCALAPPDATA%` is the fallback in
the normal packaged app environment.

| Path                                       | Purpose                                                                                        |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| `%LOCALAPPDATA%\noctty\config.ghostty`     | User config, written on first launch.                                                          |
| `%LOCALAPPDATA%\noctty\session-state.json` | Window, tab, split, profile, cwd, and title restore state when `window-save-state` is enabled. |
| `%LOCALAPPDATA%\noctty\layouts\`           | Named layouts, stored as one-window session-state JSON documents.                              |
| `%LOCALAPPDATA%\noctty\crash\`             | Local crash dumps. Nothing here is uploaded automatically.                                     |
| `%LOCALAPPDATA%\noctty\shell-integration\` | Installed shell-integration payloads and manual fallbacks.                                     |

The portable ZIP carries the bundled resources next to the executable. Do
not move `noctty.exe` alone out of the extracted tree; it needs the packaged
`share` resources for themes, terminfo, shell integration, and other data.

### Portable mode

Place a regular file named `noctty.portable`, `portable.txt`, or
`config.ghostty` beside the executable to opt into portable mode; a directory
with one of those names is not a marker. A freshly extracted ZIP is not
portable by default, because it ships `config-template.ghostty`, which is not
a marker. An empty `noctty.portable` is enough.

In portable mode, config, state, and cache live beside the executable
(`config.ghostty`, `update-state.json`, session state, crash dumps, caches).
That location takes precedence over `XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
`XDG_CACHE_HOME`, and `%LOCALAPPDATA%`, so the folder moves as one unit
without leaving runtime data on the host. If `%LOCALAPPDATA%\noctty` already
holds data, startup warns that portable mode is using the adjacent data
instead; nothing is migrated.

## Shells

The profile picker detects:

- PowerShell 7+ (`pwsh.exe`)
- Windows PowerShell (`powershell.exe`)
- Command Prompt (`cmd.exe`)
- Git Bash
- WSL distributions, when `wsl.exe` is installed and responsive

Shell integration is automatic for PowerShell and for directly launched
Unix-like shells such as Git Bash. WSL sessions manage their own
integration inside the distribution. PowerShell integration emits OSC 7
working-directory updates and OSC 133 prompt markers.

For `cmd.exe`, noctty wraps the inherited `PROMPT` (or cmd's `$P$G` default)
so the shell emits OSC 133 A/B prompt marks and an OSC 9;9 working-directory
report; a `PROMPT` set through `env = PROMPT=...` is applied afterward and
replaces the wrapper. If `clink.bat` or `clink_x64.exe` is found under
`%LOCALAPPDATA%\clink` or on a local, mounted, drive-qualified `PATH` entry
(remote, UNC, and relative entries are skipped so a dead network path cannot
stall a new tab), noctty prepends its shipped Lua directory to `CLINK_PATH`.
That only makes the script discoverable once Clink is already active through
autorun, `clink inject`, or an explicit Clink launch; noctty never injects or
launches Clink. When loaded, the script adds OSC 133 C/D command marks and the
exit code before the next prompt, truthful only while Clink's
`cmd.get_errorlevel` setting is enabled (its default). Without it, prompt
navigation and cwd reporting still work, but there are no command-finish marks
or exit codes.

Caveats: on a UNC working directory `$P` yields `\\server\share\dir`, which
noctty reports unchanged, but cmd.exe itself cannot use a UNC cwd (it warns and
falls back), so a new cmd tab or split will generally not land on the share. A
`PROMPT` ending in an odd number of `$` gets a `$S` (one space) inserted before
the closing mark so cmd does not pair the dangling `$` with the mark's `$E`.
`PROMPT` is session-wide, so `echo on` batch runs and `cmd /c` children can
echo the wrapped value and emit spurious OSC 133 marks.

With OSC 133 shell integration active, the command palette also offers:

- `jump_to_prompt:-1` / `jump_to_prompt:1` (`Ctrl+Shift+PageUp` /
  `Ctrl+Shift+PageDown`): previous / next prompt.
- `copy_last_command_output` (`Ctrl+Shift+Y`): copy the last completed
  command's output. Needs OSC 133;C and OSC 133;D boundaries.
- `insert_last_command` (no default keybind): put the last recoverable
  single-line command back on the prompt without submitting it. Needs OSC
  133;B and OSC 133;C boundaries; noctty never reads or modifies the shell's
  line editor. It refuses on the alternate screen, while a command is running,
  and when no OSC 133;B input mark is outstanding (pressing Enter, or pasting
  a line terminator, consumes the mark until the shell draws the next prompt,
  which matters for the A/B-only cmd.exe integration), and it rejects text
  that is empty, multi-line, over 4096 bytes, or carries control or invisible
  formatting characters. It does not press Enter, by design: OSC 133 marks
  carry no provenance, so any program that can print (a file you `type`, a log
  you tail, a host you SSH into) can forge a complete A/B/C/D lifecycle around
  text of its choosing and have it retained as "the last command". The text is
  inserted the way a clipboard paste is (bracketed when the terminal asked for
  it); you read what landed on the prompt and submit it yourself.

After a resize or repaint, ConPTY can redraw the whole screen and retag
previously marked cells as output, so a recovered command or output region may
occasionally be unavailable or truncated afterward.

`utf8-console` (`auto`, `always`, `never`) controls UTF-8 setup for bare
interactive `cmd.exe` launches and for Windows PowerShell 5.1 and PowerShell 7
sessions. `auto` (the default) enables UTF-8 unless the machine ANSI or OEM
code page is a legacy CJK page (932, 936, 949, 950, or 1361); `always` ignores
that guard; `never` leaves the encoding alone. The cmd preamble applies only to
an interactive launch with no `/c`, `/r`, or `/k` payload: option switches such
as `/d`, `/q`, and `/v:on` are kept in order ahead of it, and it is a no-op
when the console already uses code page 65001. The PowerShell half runs inside
the injected shell-integration script, so it does nothing with
`shell-integration = none` or a command line that injection declines
(`-Command`, `-File`, `-EncodedCommand`, `-NonInteractive`). WSL and Git Bash
are unaffected.

WSL appears in the picker but never becomes the default shell implicitly,
because `wsl.exe --status` can report a healthy installation even when
launching a session would fail. To make it the default:

```ini
command = wsl.exe
```

## SSH hosts

noctty reads `%USERPROFILE%\.ssh\config` read-only whenever Windows
profiles are refreshed. Each concrete alias on a `Host` line appears as
`SSH: <alias>` in the profile picker and `Connect to <alias>` in the
universal palette. Opening either runs the system `ssh.exe` with the alias
as its only argument, in a new tab in your home directory. Set
`ssh-config-hosts = false` to remove these entries.

- Only `Host` lines are read. A line may carry several aliases. Wildcard or
  negated patterns, and aliases that are not plain printable ASCII, are
  skipped.
- Every other keyword (`HostName`, `User`, `Port`, `ProxyCommand`, and the
  rest) is left to `ssh`, which reads the same file. `Match` blocks are
  ignored, including their `Include` lines.
- `Include` files are read one level deep, up to 16 files. Relative paths
  start at the `.ssh` directory; absolute and `~/` paths are accepted. A
  leading `"` groups one path containing spaces, as in OpenSSH. A backslash
  is a path separator, not an escape.
- An include is skipped before it is opened when it is globbed, UNC
  (`\\server\share`), a device path (`\\?\`, `\\.\`), or a mapped network
  drive letter. The drive check uses `GetDriveTypeW`, which answers from the
  local mount table without contacting the server. It misses a directory
  junction or `subst` alias with a remote target, but the bounded worker
  still keeps that open off the UI thread.
- The root config and `Include` opens run off the UI thread under one shared
  50 ms refresh budget. A slow or blocked path is skipped; a later profile
  refresh can retry it.

Activating an entry runs `ssh <alias>`, so whatever the alias resolves to in
your SSH configuration takes effect, including any `ProxyCommand` or
`LocalCommand`, which run locally. noctty adds no execution of its own; it
turns the file into a one-click surface.

SSH entries run without shell integration, which is injected into a local
shell and cannot apply to a remote session. Session restore does not reopen
them: an SSH pane comes back as the default shell rather than dialing out
unattended. SSH entries sort after the detected shells;
`NOCTTY_WIN32_PROFILE_ORDER` covers shell profiles only. There is no bundled
SSH client, secrets vault, or fleet/connection management.

## App identity

Installed builds create Start menu shortcuts with noctty's AppUserModelID,
which Windows uses for taskbar grouping and Action Center toast activation.
Portable builds have no installer-created shortcuts, so taskbar and
notification identity may be less stable. If Windows shows a stale icon
after upgrading or switching between installed and portable builds, restart
Explorer or clear the icon cache before assuming the build is broken.

## Default terminal

> [!WARNING]
> Default-terminal registration is experimental. A delegated console
> application is now adopted into a visible noctty window, but noctty cannot
> appear in the Windows Settings picker and ships no console half of its own.
> Register only on a machine you can restore, and unregister after testing.

```powershell
noctty +register-default-terminal
noctty +unregister-default-terminal
```

Both commands are idempotent. Registration writes only per-user (`HKCU`)
selection and COM proxy state; the installer registers noctty's owned COM
local-server and proxy classes machine-wide but does not change any user's
default terminal. Portable builds can register the absolute paths of the
current `noctty.exe` and its sibling `noctty-terminal-handoff-proxy.dll`;
moving either file afterward requires registering again. Registration
refuses to proceed when the proxy DLL is missing, or when
`DelegationConsole` is missing, empty, or set to the inbox console host.

The three shared Microsoft `ITerminalHandoff` Interface mappings are
snapshotted before noctty changes them. Unregistration restores each prior
raw value only while that mapping still points to noctty's proxy, so a newer
terminal's registration is preserved. It restores the `DelegationTerminal`
value saved at registration only when noctty is still selected, then removes
noctty's per-user COM registration. It never overwrites a default-terminal
choice made after noctty was registered.

noctty implements the terminal half of Windows console delegation and needs
a Windows Terminal OpenConsole installation to remain selected as the console
half. It does not verify that the selected console CLSID still resolves to
an installed application, so a value left behind by an uninstalled Windows
Terminal is accepted and console launches degrade until a working console
half is selected again. The handoff supports `ITerminalHandoff3` only, as
used by Windows Terminal 1.24 or newer. Older OpenConsole versions that
request v1 or v2 are not supported; Windows falls back to a normal console
window.

noctty is an unpackaged application, so it does not appear in the Windows
Settings default-terminal picker; the registration command writes the
per-user registry values directly. Candidate enumeration accepts a console
and terminal pair only when both come from the same package, and selecting
anything in the picker overwrites noctty's pair. Package identity would be
required to fix this.

For a handoff trace, set `NOCTTY_HANDOFF_TRACE=1` before launching the
delegated console application. noctty appends `event=` milestone lines and
`reason=`/HRESULT rejection lines to `%LOCALAPPDATA%\noctty\handoff.log`,
which distinguishes "never activated" from "adopted, then lost on the way to
a window". The opt-in file is truncated before an append would exceed 1 MiB.

### Security properties of registration

Registration creates a same-user activation surface, which is inherent to
Windows console delegation. Once registered, any local process running as
the same user at the same integrity level can activate noctty's handoff
class directly and call `EstablishPtyHandoff` with pipes and a window title
it controls. The result is a real noctty window rendering that process's
content, with the user's keystrokes flowing back to it: a phishing shape,
for example a window titled `Administrator: Windows PowerShell`. No
privilege boundary is crossed; such a process already runs as the user and
could impersonate a terminal in other ways.

The handoff rejects callers whose integrity level does not match noctty's
own. That rejection must stay: it stops an elevated console session from
being rendered inside a medium-integrity terminal that the user's other
processes can drive.

The per-user `Interface\{IID}\ProxyStubClsid32` mappings are required for
normal console-delegation clients, but they are configuration, not an
access-control boundary. A same-user medium-integrity process can create an
equivalent HKCU mapping to the installer-published proxy class and activate
the handoff class directly, even before the registration command has run.

`EstablishPtyHandoff` returns the two OpenConsole-side pipe ends as
`[out] system_handle(sh_pipe)` parameters, and that marshaling transfers
ownership: once the method returns `S_OK` the RPC stub duplicates each handle
into the client and closes noctty's original. noctty therefore drops those
two handles at the point of return and never closes them again. Closing them
afterwards is a double close, and `std.os.windows.CloseHandle` asserts that
`NtClose` succeeded, so it aborts the process before the adopted session can
become a window.

## Taskbar jump list

- Recent: up to 10 absolute local working directories reported by shell
  pwd/OSC integration, newest first. Selecting one launches noctty in that
  directory. Entries persist in
  `%LOCALAPPDATA%\noctty\jump-list-recents.json`. To clear them, close
  noctty, delete that file, and start noctty once so Windows receives the
  empty list.
- Profiles: the detected shell profiles. Selecting one launches noctty with
  that profile's command.

### Explorer context menu

| Explorer target   | Classic verb key                    |
| ----------------- | ----------------------------------- |
| Selected folder   | `Directory\shell\noctty`            |
| Folder background | `Directory\Background\shell\noctty` |
| Drive             | `Drive\shell\noctty`                |

Each verb is named `Open noctty here` and launches `noctty.exe` with
`--single-instance=false --working-directory="%V\."`. The explicit new
instance keeps the selected path in the launched process, so UNC folders do
not cross the single-instance IPC boundary, which rejects UNC working
directories. The trailing `\.` is required: Explorer expands `%V` for a
drive root as `C:\`, and a backslash right before the closing quote would be
read as an escaped quote when Windows splits the command line.

The installer writes the verbs under `HKA\Software\Classes`. The current
administrative install mode maps `HKA` to `HKLM` and `{autopf}` to the
common Program Files directory; in non-administrative mode Inno Setup maps
`HKA` to `HKCU` and `{autopf}` to the user Program Files directory.

Portable users opt in per-user under `HKCU\Software\Classes` with
`noctty +register-shell-menu` and remove the same six owned keys with
`noctty +unregister-shell-menu`. The running app never registers these verbs
itself and never writes them to `HKLM`. A per-user verb wins over a
per-machine one, because `HKCU\Software\Classes` overrides `HKLM` in the
merged `HKCR` view. So if you registered the verbs from a portable build and
later install noctty per-machine, the per-user copy keeps pointing at the
portable executable until you remove it: before deleting a portable copy,
run `.\noctty.com +unregister-shell-menu` as the user that registered the
verbs. The installer's uninstaller removes only its own registration.

On Windows 11 these classic verbs appear under **Show more options**;
`Shift+F10` opens the classic menu directly. There is no top-level modern
command. Shipping one requires a sparse MSIX manifest with package identity,
an `IExplorerCommand` COM server, `windows.comServer` plus
`Windows.FileExplorerContextMenus` (`windows.fileExplorerContextMenus` in the
manifest) extension registration, and a signed package whose Publisher
matches the signing certificate. The current self-signed release certificate
must be trusted explicitly on each machine before Windows accepts such a
package.

## Notifications and progress

Desktop notifications use WinRT toasts when available and fall back to
in-app banners when Windows notification policy, Focus Assist, app identity,
or runtime availability prevents a toast. `desktop-notifications` gates every
toast, including command-finish toasts, which additionally need
`notify-on-command-finish` and a `notify-on-command-finish-action` that
includes `notify`. Only command-finish toasts focus the originating pane when
clicked; OSC 9 and OSC 777 toasts are display-only.

Terminal progress reports map to Windows taskbar progress for the active
surface in each host window when `progress-style` is enabled; with
`progress-style = false` the sequences are silently ignored. Terminal apps
can also set in-terminal progress state through Ghostty's shared VT/OSC
support.

## Power and battery

noctty reads AC/battery and saver state from `GetSystemPowerStatus` and
subscribes to Windows power-setting notifications for the power source
(`GUID_ACDC_POWER_SOURCE`) and Battery Saver (`GUID_POWER_SAVING_STATUS`).
It also registers for Windows 11 Energy Saver (`GUID_ENERGY_SAVER_STATUS`),
which can engage while plugged in; Microsoft currently documents that GUID
as prerelease, so registration is best-effort and has no effect on Windows
builds that lack it. Battery Saver and Energy Saver are tracked as two
independent flags and combined with OR only when pacing is decided, so one
turning off cannot cancel pacing the other still requires.
`GetSystemPowerStatus` reports only Battery Saver, so the fallback query
carries the last notified Energy Saver value forward instead of clearing it.
A fallback query runs at most once every 30 seconds. None of this has been
verified on a machine with a battery; see the
[status caveats](status.md#known-caveats).

- `unfocused-render-fps` caps presentation for visible, unfocused surfaces.
  Default `30`. Values below `1` are treated as `1`; values above `125` have
  no additional effect, because the renderer never presents more often than
  every 8 ms.
- `power-saver-rendering` accepts `auto`, `on`, or `off`. Default `auto`,
  which follows Windows Battery Saver or Energy Saver; `on` forces saver
  pacing and `off` disables it. `auto` does not key off battery power alone:
  running unplugged with saver off keeps the normal cadence, because
  throttling a focused terminal just because a laptop is unplugged is a far
  more aggressive default than following the saver signal the user opted
  into.

Focused surfaces keep their normal cadence when saver pacing is inactive.
Saver pacing caps presentation at about 30 fps. Minimized and DWM-cloaked
host windows do not present until they become visible again.

Focus is per surface, not per window. In a split, only the pane with
keyboard focus presents at the full rate. The other panes count as unfocused
even though you can see them, so a split tailing fast output next to your
active pane is capped at `unfocused-render-fps` (30 by default). Raise that
value if you watch live output in a background split.

Cloak and uncloak have no window message, so noctty hooks the documented
`EVENT_OBJECT_CLOAKED` / `EVENT_OBJECT_UNCLOAKED` WinEvents with a single
`SetWinEventHook` scoped to this process and the UI thread. Without it, a
virtual-desktop switch that uncloaks a background window need not send
`WM_ACTIVATE`, `WM_SHOWWINDOW`, or `WM_WINDOWPOSCHANGED`, and since hidden
surfaces skip rendering entirely there would be no path back to visible.
Those messages remain as a fallback for a missed event or a failed hook
registration, which degrades to the previous behaviour rather than failing
window creation. The callback forwards which event fired; the refresh it
triggers re-queries `DwmGetWindowAttribute(DWMWA_CLOAKED)`, and if that
query fails the observed transition is used instead of the last known cloak
state, because a stale "cloaked" across an uncloak would leave the window
hidden with nothing left to re-query it. This hook path is argued from the
Win32 contract and covered by unit tests over the pure event filter and the
pure cloak-resolution policy. It has not been observed on hardware; see the
[status caveats](status.md#known-caveats).

Set `NOCTTY_RENDER_TRACE_FILE` to an absolute output path to write a JSON
render trace when the first traced surface is destroyed. Presented fps is
`(swap_buffers_count - 1) * 1000 / (last_swap_at_ms - first_swap_at_ms)`
when at least two swaps are present and the time difference is positive.

## Keyboard

Key events are translated with the active Windows keyboard layout, so the
terminal receives the text a key produces on that layout rather than a
US-layout approximation. Control chords are encoded from the unmodified
layout text: `ctrl+c` sends `0x03`, and combinations with no C0 byte
(`ctrl+,`, `ctrl+.`, `ctrl+m`, `ctrl+i`, `ctrl+[`) send the fixterms
`CSI <codepoint>;5u` form that editors such as Neovim and Helix understand.

AltGr is a layout shift, not a Ctrl+Alt chord. Windows synthesizes left Ctrl
plus right Alt whenever AltGr is pressed, and noctty drops that synthetic
pair so `AltGr+<key>` produces the layout character (or nothing) instead of
a Ctrl+Alt terminal sequence. The collapse applies only on layouts that
define AltGr mappings, the only layouts where Windows injects the synthetic
Ctrl. On a layout without AltGr, such as plain US, left Ctrl plus right Alt
can only be a chord you pressed and passes through as one. On a layout with
AltGr, the modifier state noctty reads cannot tell the two apart, so left
Ctrl plus right Alt is always read as AltGr there; use left Alt or right
Ctrl for a deliberate Ctrl+Alt chord.

While a program has the Kitty keyboard protocol's `report_all` flag enabled,
typed text travels on the physical key event rather than a separate character
commit, so the press and release a program pairs share one key identity. This
includes AltGr characters and dead-key sequences. `key-remap` affects
keybinds and terminal encoding but not `global:` hotkeys, which register the
literal chord you configured.

Console applications reached through ConPTY see these sequences through
conhost's own decoder, which does not translate every form back into a
console key record. `[Console]::ReadKey()` therefore reports less than the
terminal sent; applications that read the byte stream directly see
everything. Measured on both ConPTY sources, an unrecognised CSI-u key
encoding is not dropped: ConPTY hands the child the same bytes noctty wrote.
See the
[key encoding differential](windows-vt-conformance.md#measured-master-to-child-key-encoding-differential).

`F6` and `Shift+F6` run `cycle_focus_region` and move keyboard focus
between the terminal pane, the tab strip, the docked search query, and the
host banner, skipping whatever is not on screen. `Esc` returns to the
terminal. In the tab strip, Left/Right/Home/End move between tabs,
Enter or Space activates one, `Delete` closes one, `F2` renames, and Ctrl
with an arrow or Home/End moves the tab. These chrome keys are fixed:
chrome controls are native windows that never reach the keybind path, so
rebinding `cycle_focus_region` changes only the terminal end of the cycle.
The command palette and other overlays keep their own focus handling and
are not part of the cycle.

## Windows, tabs, and splits

The native Win32 host window provides a tab bar with overflow handling,
same-window drag reorder, and exact-pane drag-to-split with reversible
subtree transfer; horizontal and vertical splits; per-monitor DPI handling;
a DWM dark caption; high-contrast palette switching; IME support;
drag-and-drop of files, plain text, URLs, and HTML into a pane; and native
right-click context menus.

The dark caption is chosen at runtime, not by build number:
`DWMWA_USE_IMMERSIVE_DARK_MODE` (20) is tried first and the legacy attribute
(19) is used when DWM rejects it. Windows 11 additionally gets an integrated
title bar (app-owned caption with native caption actions and Snap Layout
hover) while the tab bar and window decorations are visible;
`window-show-tab-bar = never` or hidden decorations fall back to the stock
caption, as do older builds.

The universal palette puts actions, live tabs, panes, Windows profiles,
named layouts, and native settings in one fuzzy-ranked, keyboard-driven
list. Type a prefix to filter one category: `>` actions, `@` tabs, `/`
panes, `~` profiles, `:` settings, `%` themes, `!` recent commands, `^`
layouts, or `?` for help. The native Settings window stages edits until Save
and patches your config without rewriting unrelated text. Details for both
are in the [capability matrix notes](windows-capability-matrix.md#notes).

## Running elevated

Use **New Elevated Window** in the command palette, or bind
`new_window_elevated:`. The empty payload uses the current/default Windows
shell profile; `new_window_elevated:<profile-key>` selects a detected profile
by key. Windows shows a UAC prompt before the new process starts. Cancelling
the prompt leaves the current window unchanged. The relaunch call is
synchronous, so the initiating window is unresponsive while the UAC prompt is
open.

The roadmap originally asked for a per-profile `run elevated` flag. Windows
profiles in noctty are detected from installed shells rather than declared in
a user-authored profile schema, so there is no profile property to set. The
per-profile equivalent is a `new_window_elevated:<profile-key>` binding.

An elevated noctty is a separate process and a separate window. Its title is
prefixed with `Administrator: `. Elevated and non-elevated tabs cannot be
mixed in one window: Windows isolates the processes with UIPI, and injecting a
shell across that boundary is not a supported design.

Single-instance IPC is scoped by integrity level. A normal launch and
`+new-window` forward only to an existing noctty at the caller's integrity
level. From an elevated shell, `+new-window` therefore opens in the elevated
group (and starts an elevated noctty when that group is absent). A
default-terminal handoff from an elevated console lands in that same
`.elevated` group. The automation surface is scoped identically:
`+list-windows` sees only its integrity group and `+perform-action` can target
only windows in that group. The same commands from a non-elevated shell see
only the non-elevated group; neither direction silently forwards or automates
a window across the integrity boundary.

Toast activation, Explorer, and jump-list launches start a medium-integrity
process. They cannot activate into an existing elevated window and instead use
or start the `.medium` group.

A split-token elevated process (`TokenElevationTypeFull`) does not read or
write `%LOCALAPPDATA%\noctty\session-state.json`. It never restores an earlier
workspace, overwrites the non-elevated saved workspace, or gets resurrected by
session restore. With UAC disabled, or under the built-in Administrator
account, Windows reports the process as elevated but uses the default token
elevation type. In that case the `Administrator: ` title prefix and
`.elevated` pipe grouping still apply, while session restore remains enabled
because there is no non-elevated split-token counterpart to protect.
Configuration and other per-user state still resolve from the same
`%LOCALAPPDATA%\noctty\` profile as the non-elevated process.

An elevated noctty loads the same `%LOCALAPPDATA%\noctty\config.ghostty` and
the same explicit `--config-file` overrides as a non-elevated process. Those
files remain writable by the ordinary user account, so anything that can
modify the configuration, including `command`, `shell-integration`, and theme
paths, runs at high integrity the next time an elevated window opens.

At process startup, noctty restricts bare-name DLL resolution to the
application directory, System32, and explicitly added DLL directories. The
current directory and inherited `PATH` are excluded from that search order.

UIPI also prevents files from being dragged from non-elevated Explorer into
an elevated noctty window. No message-filter exception is installed; use a
shell command or an elevated file manager when the elevated terminal needs a
path.

Global bindings remain desktop-wide Win32 `RegisterHotKey` registrations.
Whichever noctty process registers a chord first owns it, regardless of the
process integrity level; a later process logs a registration conflict. The
losing process retries on configuration synchronization or restart, not
automatically when the winner exits.

## Session restore and recovery

Session restore persists host windows, tabs, split layout, selected
profiles, working directories, and explicit titles. It does not restore
child process state. Terminal contents come back only when
`window-save-state-scrollback` is set to a nonzero line count; the default
is `0` (off) because terminal output becomes data at rest and can contain
secrets. The value is a request clamped to 10,000 lines, not a guarantee:
all panes share a 512 KiB encoded budget, each pane is pre-limited by its
current width, and any line over 16 KiB is omitted, so wide panes and panes
captured later can keep fewer lines.

Snapshots are plain text without colors or styles. Soft-wrapped rows become
separate hard lines, a row containing invalid UTF-8 or control bytes other
than tab is dropped whole rather than sanitized, and a capture taken while
the alternate screen is active records the TUI screen instead of the shell
history. Each restored pane ends with a
`--- RESTORED SNAPSHOT END | ...Z ---` separator carrying the capture time,
and the whole snapshot sits above the live prompt in scrollback so the
shell's startup repaint cannot destroy it. Engaging `toggle_secure_input`
once excludes that pane from snapshots for the rest of the session, even if
the indicator is later turned off.

If the session-state file is unreadable, noctty moves it aside to a sibling
with a `.corrupt` suffix, logs the failure, and starts with a fresh window.
When an earlier quarantine file already exists, a numeric suffix is added
(`.corrupt.1`, `.corrupt.2`, and so on) so nothing is overwritten. If the
move fails, the original file is left untouched. Older builds parse the
schema strictly, so downgrading while a saved state contains `scrollback`
can quarantine that file as `.corrupt`.

A snapshot that merely exceeds the limits above (too many lines, a line over
16 KiB, or the shared budget) is dropped on load and the window's layout still
comes back. A snapshot of the wrong shape, such as a hand-edited
`"lines": "not-an-array"`, makes the whole document malformed and takes the
quarantine path instead, so that window's layout is not restored. Nothing is
deleted either way.

Three consecutive pre-ready startup failures select an ephemeral safe mode:
built-in config, no session restore. `noctty --safe-mode` picks it for one
launch. Safe mode never overwrites your config or quarantined state.

## Named layouts

A named layout captures the focused window's tabs, split trees, selected
profiles, working directories, and explicit pane and tab titles. It omits
window position, size, and state. Each layout is the session-state JSON
schema with exactly one window, stored as
`%LOCALAPPDATA%\noctty\layouts\<name>.json`. Per-pane commands come from the
saved profiles; layout files have no separate command field.

- Names accept ASCII letters, digits, spaces, dots, underscores, and
  hyphens, up to 64 bytes. Leading or trailing spaces and dots are rejected,
  as are Windows reserved device names such as `CON` or `COM1`.
- A corrupt or structurally invalid layout file is quarantined with the same
  `.corrupt` rules as session state. A transient read failure is reported
  without quarantining, so a locked or briefly unavailable layout is not
  moved aside.
- A layout that would open more than 16 tabs or 64 panes is refused without
  quarantine.
- Window position, size, and maximized state are stripped before validation
  and ignored on launch; a layout describes a shape, not a placement.
  Partial or stale geometry such as `x` without `y` or a zero width does not
  quarantine an otherwise valid shape.

Treat the `layouts\` directory as config-level trust. Launching a layout
starts one shell per pane, using the working directories and profiles the
file names. Anyone who can write to that directory can influence what your
next layout launch runs, exactly as they could by editing your config.

Bind `save_layout:<name>` to save or atomically replace a layout, and
`launch_layout:<name>` to open it in a new window. Saved layouts also appear
in the command palette as `Launch layout: <name>`. From the command line,
`noctty +new-window --launch-layout=<name>` forwards the request to a
running instance or launches cold when none is running.

The warm (running-instance) half of that command is not a forwarded
configuration argument. It is a dedicated IPC request whose whole payload
is the layout name, revalidated on the receiving side against the same
character, length, traversal, and reserved-device rules the CLI applies, and
resolved server-side against `%LOCALAPPDATA%\noctty\layouts\`. So
`--launch-layout` cannot be combined with other `+new-window` arguments;
mixing them is refused. `launch-layout` is not on the forwarded-argv
allowlist and will not be added: a layout names a file that selects
profiles, profiles carry commands, and code selection is what that allowlist
exists to refuse. The keybind and the command palette do not go over IPC at
all.

`--launch-layout` is a command-line-only, one-shot option. Setting
`launch-layout` in `config.ghostty` is ignored with a warning, because a
configuration file is read on every start and the layout would replay on
each launch. The layout module also exposes name enumeration and the
`+new-window --launch-layout=<name>` argv builder for future jump-list
integration; noctty does not currently add jump-list layout entries.

## Updates

```ini
auto-update = check
```

The updater checks the configured release feed at most once every 24 hours
and never replaces binaries silently. The feed defaults to noctty's GitHub
Releases API and can be changed with `auto-update-feed-url`; checksum,
Authenticode, and pinned-publisher-key verification stay mandatory whatever
the feed host. For tests and diagnostics, `NOCTTY_UPDATE_FEED_URL` overrides
the compiled-in default when no explicit `auto-update-feed-url` is set. The
precedence is explicit config, then the environment variable, then the
compiled-in default; a blank or whitespace-only value at either level falls
through to the next, and a value that is not a valid HTTPS URL is ignored
with a warning. Changing the effective feed discards the previous feed's
cached release, dismissal, and staged installer. In `check` mode it opens the
release page when a newer stable version exists. It is the only outbound
network call the app makes; there is no telemetry and no analytics.

Upstream Ghostty is leaving GitHub, so the maintainer periodically checks
that the `upstream` remote and the release-feed host are still live and
re-points them if either moves.

`auto-update = download` downloads only stable Windows releases that ship
architecture-specific SHA256 metadata, verifies the selected installer or
portable ZIP against that manifest, and requires a valid Windows Authenticode
signature before staging it under the local noctty state directory. Portable
updates additionally require a signed payload-manifest asset whose SHA-256
entries cover every extracted file, and every extracted `.exe`, `.com`, and
`.dll` must pass its own Authenticode check. The signature check is not
generic: the signer's public key must match a SHA-256 SPKI pin compiled into
the app, so a binary signed by any other key is rejected even when its
signature is otherwise valid. Unsigned binaries fail that verification too.
The bundled Microsoft `conpty.dll` and `OpenConsole.exe` are the two
exceptions, because noctty never re-signs them: each must match the SHA-256
pinned in `dist/windows/conpty-redist.json` and carry a signature that chains
to a trusted root, which is stricter about the chain than the pinned-publisher
path. Every other PE keeps the publisher pin.
See
[ADR 0005](adr/0005-pin-updater-publisher-public-keys.md) for the pinning
and key-rotation rules.

For installer-managed installs, the update notice can launch the verified
staged installer. Applying an update is always user-initiated: it
re-verifies the staged installer, records apply intent, launches the
installer elevated (UAC may prompt), and exits the app.

For portable installs, **Apply** re-verifies the staged ZIP payload, records the
pending update, and exits noctty. On the next launch, noctty backs up the files
being replaced, swaps in the staged payload, and starts the new build. The new
build confirms the update only when its version matches the staged target;
otherwise noctty restores the backup. A new build that exits with an error
during the bounded startup check, or a swap that remains unconfirmed on a later
launch, also rolls back and relaunches the previous build.

If recovery files are lost after a swap, noctty abandons the unrecoverable
transaction, launches the installed build, and shows a warning with manual
recovery guidance. `NOCTTY_PORTABLE_UPDATE_BYPASS=1` is the manual escape hatch
for portable-update startup recovery: set it only for the process being
launched to skip that recovery attempt. This bypass does not verify, complete,
or roll back the update, so reinstall or update manually afterward if the
installed build is inconsistent.

Portable apply fails closed until a release publishes that signed complete-file
manifest. Releases without it are not downloaded or staged for portable apply;
the update notice opens the normal GitHub release page for manual updating.

## Quick select & copy mode

`Ctrl+Shift+Space` runs `toggle_quick_select` for the focused terminal
surface. Quick select scans the visible viewport once when it opens and
labels matching URLs, paths, git SHAs, IP addresses, and UUIDs. Type a label
to select its target. Backspace removes one typed label character; Esc
cancels and returns keyboard focus to the terminal. Quick select also closes
on resize, on a click, and when the surface loses focus.

Completing a label copies the matched text to the clipboard. Hold Ctrl while
completing to open a target that begins with an allowed URL scheme; other
targets are copied. Hold Alt to paste through the normal protected-paste
path. Opening is narrower than matching: `file:` URLs are labeled and can be
copied, but Ctrl will not open them, because the system handler would run
`file:///C:/...exe` straight from terminal output. Alt-paste also runs the
same classifier as the drag-and-drop path, so a match carrying shell
metacharacters, environment-variable expansion, or control bytes raises the
paste confirmation.

Targets are re-checked against the live screen when you act. If the running
program rewrote a labeled region while the overlay was up, that target is
ignored, so you only act on what was on screen.

`quick-select-patterns` is repeatable and accepts bare regex values or
quoted Zig string literals. An empty value clears configured patterns; when
the configured list is empty, the built-in patterns apply.
`quick-select-alphabet` sets the unique printable ASCII characters used for
labels. It requires at least two characters and treats ASCII letters that
differ only by case as duplicates. Use Zig string literal syntax to preserve
leading or trailing spaces.

`Ctrl+Shift+X` runs `toggle_copy_mode`. Copy mode starts a selection at the
terminal cursor when it is visible, or at the bottom edge of a scrolled
viewport.

| Keys                                   | Action                  |
| -------------------------------------- | ----------------------- |
| `h`/`j`/`k`/`l` or arrow keys          | Move                    |
| `Ctrl+U`/`Ctrl+D` or Page Up/Page Down | Move by a viewport      |
| `g`/`G` or Home/End                    | Jump through scrollback |
| `0`/`$`                                | Jump within a line      |
| `y` or Enter                           | Copy and exit           |
| `q` or Esc                             | Cancel                  |

Other keys are consumed instead of reaching the PTY. Mouse selection and
reporting keep working: a left click replaces the copy-mode selection, and a
program with mouse reporting enabled still receives mouse escape sequences.
Legacy non-OLE file and text drop paths are ignored while copy mode owns
input; OLE drops remain mouse gestures and continue through paste inspection
and confirmation.

These bindings live in the `copy_mode` key table and can be replaced with
normal `keybind = copy_mode/...` entries. `copy_mode` is one mode, not a
re-enterable table: activating it again from a nested table does not stack a
second copy mode, and leaving copy mode unwinds every table pushed on top of
it.

## Quick terminal and global hotkeys

The quick terminal uses the same `toggle_quick_terminal` action and
`quick-terminal-*` configuration family as Ghostty where the settings map to
Windows. Global keybinds use Win32 `RegisterHotKey` while noctty is running.
Windows or other applications may reserve hotkeys first; check logs when a
global binding does not register.

`quick-terminal-keyboard-interactivity = exclusive` maps to focused input on
Windows. Global keyboard capture is intentionally not implemented.

## Automation

noctty exposes a local automation surface over the same single-instance IPC
pipe that `+new-window` uses. The verbs, JSON schema, exit codes, and policy
are in [automation.md](automation.md).

```powershell
noctty +list-windows
noctty +perform-action new_tab
noctty +perform-action --surface-id=<surface_id> toggle_fullscreen
noctty +new-tab --window-id=<window_id>
noctty +new-split --surface-id=<surface_id> --direction=right
noctty +focus --surface-id=<surface_id>
noctty +send-text --surface-id=<surface_id> -- "hello"
```

### Pipe security

The pipe accepts only processes running as the same user: it is created with
`PIPE_REJECT_REMOTE_CLIENTS`, a protected DACL that grants access to the
owning token's SID alone, and a `NO_WRITE_UP` mandatory-integrity label at the
process's exact integrity level. An elevated instance therefore refuses a
non-elevated client of the same account at `CreateFileW` (`win32=5`); the
client reports "No matching noctty instance is listening" and `+new-window`
starts its own instance instead. An elevated client still reaches the
elevated instance.

Clients authenticate the server too, because the pipe name derives from
`--class` and any local account could create it first. Before writing, a
client reads the owner SID and integrity label from the connected pipe
object; the owner must match the client's SID and the integrity must be at
least the client's, or the client treats it as no reachable instance. Clients
also connect with `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`, so a
squatting server could learn who connected but could not use the token.

The elevated endpoint is labelled `NRNW`, so a medium-integrity process
cannot open it even for `GENERIC_READ` and cannot occupy its listening
instance. Non-elevated endpoints keep the write-only-up label, where the
same occupancy behaviour still applies within one integrity level. An
elevated client additionally requires the server to be elevated, owned by the
same token user, and running the same executable image; the image check is
defence in depth, not a boundary, and refuses a forward between two different
noctty installations.

None of this is a privilege boundary. Code already running as your user can
list your windows, perform allowlisted actions, and open new windows. Treat
the channel as you would your own shell.

### Commands

`+list-windows` returns the `noctty.windows.v3` schema: instance, window,
tab, and pane metadata, including nullable pane titles and working
directories. It never includes terminal text, scrollback, selection, clipboard
contents, pending shell input, or pane process IDs.

`+perform-action` takes the same names as `keybind` values. `--surface-id` is
valid only for surface-scoped actions. The running instance refuses actions
that inject terminal input or touch arbitrary files (`text`, `csi`, `esc`,
`paste_from_clipboard`, `write_screen_file`, `end_key_sequence`,
`clear_screen`, `crash`), refuses `undo` and `redo` because they replay a
captured action, and leaves new action variants disabled until reviewed.
`launch_layout:<name>` and `save_layout:<name>` are allowed; saving is the
one action that writes a file, limited to a validated name under
`%LOCALAPPDATA%\noctty\layouts\`, written atomically, replacing an existing
layout without prompting, and only for the focused target.

### Forwarded arguments

`+new-window` forwards command-line arguments to the running instance, which
honors only allowlisted window-scoped presentation settings: window geometry
and decoration (`--window-width`, `--window-height`, `--window-position-*`,
`--window-padding-*`, `--window-decoration`, `--maximize`, `--fullscreen`),
`--title`, non-name font settings (`--font-size`, `--font-thicken`), and
colors (`--background`, `--foreground`, `--palette`, `--cursor-color`,
`--background-opacity`).

Anything that runs code (`--command`, `--initial-command`, `-e`, `--input`,
`--env`), loads a file (`--background-image`, `--custom-shader`,
`--bell-audio-path`), changes the configuration source (`--config-file`,
`--config-default-files`, `--theme`), or writes to the terminal (`--keybind`,
`--command-palette-entry`, `--enquiry-response`) is refused, and the whole
request with it. Keys not on the allowlist, including ones added later, are
refused by default.

`--working-directory` accepts `home`, `inherit`, `~/...`, or a drive-letter
absolute path. UNC paths are refused so the running instance never
authenticates to a remote SMB host; this is a syntax check, so a mapped
drive or junction can still resolve off-box.

A normal launch while an instance is running drops any argument the instance
would refuse, logs a warning, and forwards the rest so you still get a
window. The running instance re-checks every argument regardless.

## Crash reports and diagnostics

Crash dumps stay under `%LOCALAPPDATA%\noctty\crash`, and noctty never
uploads anything from it. On Windows the Sentry initialization path is a
no-op. Instead, noctty installs a local unhandled-exception filter that
writes `.dmp` minidumps for process-level crash exceptions. Some hard-abort
paths may still terminate before Windows can produce a dump.

```powershell
noctty +crash-report
noctty +diagnostic-bundle --output=noctty-diagnostics
```

`+crash-report` reads whatever is there. Dumps can contain sensitive memory
from the crashed process; review them before sharing.

`+diagnostic-bundle` writes a local-only, inspectable support bundle.
Terminal content, commands, environment, working directories, and config
values are excluded by default. Crash dumps are excluded too unless you pass
the explicit `--include-crash-dumps` flag.

## Troubleshooting

SmartScreen warns on release downloads because the current signing
certificate is self-signed and carries no publisher reputation.
[getting-started.md](getting-started.md#about-the-smartscreen-warning)
explains the warning and how to verify a download against its checksum file
first.

Desktop notifications missing: check Windows notification settings, Focus
Assist, and whether you are running an installed build with Start menu
shortcuts. In-app banners should still appear for important app notices.

Global hotkey fails: another application or Windows itself owns the same
hotkey. Pick a different trigger or close the conflicting app, then reload
config.

WSL fails to launch: set `command = wsl.exe` explicitly. If it still fails,
verify the distribution starts in a normal PowerShell session first.

### ConPTY source

`noctty +version` reports `ConPTY : bundled (<DLL path>)` or
`ConPTY : inbox`, and `+diagnostic-bundle` records the same selection. Set
`NOCTTY_CONPTY=inbox` before launch to force the in-box conhost for diagnosis.
noctty warns in-app when it falls back; the shell still works, but the tested
in-box conhost strips Kitty-graphics APC and Sixel DCS payloads. See the
[transport catalog](windows-vt-conformance.md#conpty-transport-generations-and-mangling-catalog).

### GPU floor and OpenGL driver issues

noctty needs OpenGL 4.3 or newer through WGL and has no software, DirectX,
or ANGLE fallback renderer, so it cannot start when the active OpenGL
implementation is below that floor. That is common in RDP sessions that fall
back to software GL (often `GDI Generic` at OpenGL 1.1), VMs without 3D
acceleration or a guest GPU driver, and older integrated GPUs whose driver
stops before 4.3.

Below the floor, noctty stops before showing its window and the startup
dialog lists the required and detected OpenGL versions plus the renderer and
vendor strings the driver reports. Failures later in OpenGL initialization
use the same dialog to name the failed step and any Win32 or Zig error. Try,
in order:

1. End the Remote Desktop session and launch noctty locally.
2. In a VM, enable 3D acceleration and install the guest graphics driver.
3. Update or reinstall the OEM graphics driver for the active GPU; on an
   AMD+NVIDIA hybrid system, the AMD driver first, then NVIDIA.
4. On a hybrid-GPU system, force `noctty.exe` to the discrete or integrated
   GPU in Windows Graphics settings.

If startup fails with `LoadLibrary failed with error 126` or the startup
dialog reports `Win32 error: 126 (ERROR_MOD_NOT_FOUND)` during OpenGL/WGL
initialization, Windows could not load a graphics-driver DLL or one of its
dependencies. This shows up most often on AMD+NVIDIA hybrid-GPU laptops
while WGL loads the AMD OpenGL ICD from DriverStore; use the driver order in
step 3 before retrying.

### Stale installed build

When testing a local build, make sure the `noctty` you invoke is the current
`zig-out\bin` binary rather than an older Scoop shim or a manually added
install directory earlier on `PATH`. A `noctty.com` executable may be
selected before `noctty.exe` for CLI invocations, because `.com` ranks
before `.exe` in `PATHEXT`. `noctty.com` is the console launcher and the
recommended way to run CLI actions. `noctty.exe +<action>` also works: the
Windows-subsystem binary attaches to the console it was launched from before
running the action, and leaves redirected output alone.
