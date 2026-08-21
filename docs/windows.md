# Windows

Where noctty differs from upstream Ghostty's macOS and Linux documentation.
For a row-by-row mapping against upstream docs, see
[windows-capability-matrix.md](windows-capability-matrix.md). For VT
protocol coverage validated on the Win32 runtime, see
[windows-vt-conformance.md](windows-vt-conformance.md).

## Supported systems

- Windows 10 and Windows 11 on x64 and ARM64.
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
working-directory updates and OSC 133 prompt markers. `cmd.exe` is a plain
fallback shell with no automatic prompt, cwd, or command-finish integration.

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
> Default-terminal registration is experimental and not ready for normal use.
> Live validation of this revision reaches the handoff server, but the adopted
> session closes before a visible noctty window appears. Register only on a
> disposable test account or machine, and unregister immediately after testing.

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
per-user registry values directly. Delegated applications do not yet survive
adoption into a visible noctty window.

For a one-run handoff failure trace, set `NOCTTY_HANDOFF_TRACE=1` before
launching the delegated console application. noctty appends the rejection
reason and HRESULT to `%LOCALAPPDATA%\noctty\handoff.log`. The opt-in file is
truncated before an append would exceed 1 MiB.

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

The handoff class is registered in a single-threaded apartment, and that is
load-bearing. `EstablishPtyHandoff` returns raw pty-side handles and the UI
thread closes noctty's copies later, which is safe only because the STA stub
marshals the `[out]` handles on the same thread before returning to the
message pump. Moving the class to an MTA, or running a nested modal loop
while a handoff message is dispatched, would close the handles before
conhost duplicates them and silently break every console launch.

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
or runtime availability prevents a toast. Terminal progress reports map to
Windows taskbar progress for the active surface in each host window.
Terminal apps can also set in-terminal progress state through Ghostty's
shared VT/OSC support.

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

Console applications reached through ConPTY see these sequences through
conhost's own decoder, which does not translate every form back into a
console key record. `[Console]::ReadKey()` therefore reports less than the
terminal sent; applications that read the byte stream directly see
everything.

## Windows, tabs, and splits

The native Win32 host window provides a tab bar with overflow handling,
same-window drag reorder, and exact-pane drag-to-split with reversible
subtree transfer; horizontal and vertical splits; per-monitor DPI handling;
DWM dark title bar integration; high-contrast palette switching; IME
support; drag-and-drop of files into the terminal; and native right-click
context menus.

The universal palette puts actions, live tabs, panes, Windows profiles,
named layouts, and native settings in one fuzzy-ranked, keyboard-driven
list. Type a prefix to filter one category: `>` actions, `@` tabs, `/`
panes, `~` profiles, `:` settings, `%` themes, `!` recent commands, `^`
layouts, or `?` for help. The native Settings window stages edits until Save
and patches your config without rewriting unrelated text. Details for both
are in the [capability matrix notes](windows-capability-matrix.md#notes).

## Session restore and recovery

Session restore persists host windows, tabs, split layout, selected
profiles, working directories, and explicit titles. It does not restore
child process state. Terminal contents come back only when
`window-save-state-scrollback` is set to a nonzero line count; the default
is `0` (off) because terminal output becomes data at rest and can contain
secrets.

Snapshots are plain text without colors or styles. Each restored pane ends
with a `--- RESTORED SNAPSHOT END | ...Z ---` separator carrying the capture
time, and the whole snapshot sits above the live prompt in scrollback so the
shell's startup repaint cannot destroy it. Engaging `toggle_secure_input`
once excludes that pane from snapshots for the rest of the session, even if
the indicator is later turned off.

If the session-state file is unreadable, noctty moves it aside to a sibling
with a `.corrupt` suffix, logs the failure, and starts with a fresh window.
When an earlier quarantine file already exists, a numeric suffix is added
(`.corrupt.1`, `.corrupt.2`, and so on) so nothing is overwritten. If the
move fails, the original file is left untouched.

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

The updater calls `api.github.com/repos/amanthanvi/noctty/releases/latest`
at most once every 24 hours and never replaces binaries silently. In `check`
mode it opens the release page when a newer stable version exists. It is the
only outbound network call the app makes; there is no telemetry and no
analytics.

`auto-update = download` downloads only stable Windows installer releases
that ship architecture-specific SHA256 metadata, verifies the installer's
SHA-256 against that manifest, and requires a valid Windows Authenticode
signature before staging the installer under the local noctty state
directory. The signature check is not generic: the signer's public key must
match a SHA-256 SPKI pin compiled into the app, so an installer signed by
any other key is rejected even when its signature is otherwise valid.
Unsigned installers fail that verification too, and neither is staged. See
[ADR 0005](adr/0005-pin-updater-publisher-public-keys.md) for the pinning
and key-rotation rules.

For installer-managed installs, the update notice can launch the verified
staged installer. Applying an update is always user-initiated: it
re-verifies the staged installer, records apply intent, launches the
installer elevated (UAC may prompt), and exits the app. Portable ZIP
auto-apply is not implemented yet.

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

Known limitation: the label denies writes, not reads. A medium-integrity
process can open an elevated instance's pipe for `GENERIC_READ`, learn and
submit nothing, but occupy the single listening instance until the server's
read timeout, so the next real client fails with `ERROR_PIPE_BUSY`. Labeling
the elevated endpoint `NWNR` closes this and is planned with the elevation
work.

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

### OpenGL driver issues

noctty needs OpenGL 4.3 or newer. If the window fails to render or exits
early on older hardware, update GPU drivers before filing a rendering bug.

If startup fails with `LoadLibrary failed with error 126` or the startup
dialog reports `Win32 error: 126 (ERROR_MOD_NOT_FOUND)` during OpenGL/WGL
initialization, Windows could not load a graphics-driver DLL or one of its
dependencies. This shows up most often on AMD+NVIDIA hybrid-GPU laptops
while WGL loads the AMD OpenGL ICD from DriverStore. Try, in order:

1. Update or reinstall the OEM AMD graphics driver, then the NVIDIA driver.
2. Force `noctty.exe` to the discrete or integrated GPU in Windows Graphics
   settings.

noctty ships only the OpenGL/WGL renderer on Windows. There is no DirectX or
ANGLE fallback renderer in this build.

### Stale installed build

When testing a local build, make sure the `noctty` you invoke is the current
`zig-out\bin` binary rather than an older Scoop shim or a manually added
install directory earlier on `PATH`. A `noctty.com` executable may be
selected before `noctty.exe` for CLI invocations, because `.com` ranks
before `.exe` in `PATHEXT`. `noctty.com` is the console launcher and the
recommended way to run CLI actions. `noctty.exe +<action>` also works: the
Windows-subsystem binary attaches to the console it was launched from before
running the action, and leaves redirected output alone.
