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

| Path                                       | Purpose                                                                                        |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| `%LOCALAPPDATA%\noctty\config.ghostty`     | User config written on first launch.                                                           |
| `%LOCALAPPDATA%\noctty\session-state.json` | Window, tab, split, profile, cwd, and title restore state when `window-save-state` is enabled. |
| `%LOCALAPPDATA%\noctty\layouts\`          | Named layouts, stored as one-window session-state JSON documents.                             |
| `%LOCALAPPDATA%\noctty\crash\`            | Local crash dump directory. Nothing here is uploaded automatically.                           |
| `%LOCALAPPDATA%\noctty\shell-integration\` | Installed shell-integration payloads and manual fallbacks.                                    |

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
working-directory updates and OSC 133 prompt markers. `cmd.exe` is a
plain fallback shell today, with no automatic prompt, cwd, or
command-finish integration.

WSL shows up in the picker, but it never becomes the default shell
implicitly, because `wsl.exe --status` can report a healthy installation
even when launching a session would fail. To make it your default, opt
in explicitly:

```ini
command = wsl.exe
```

## SSH hosts

By default, noctty reads `%USERPROFILE%\.ssh\config` read-only whenever
Windows profiles are refreshed. Each concrete alias on a `Host` line appears
as `SSH: <alias>` in the profile picker and `Connect to <alias>` in the
universal palette. Opening either entry starts the system `ssh.exe` with only
the alias as its argument, in a new tab whose working directory is the user's
home directory.

Only `Host` lines are read. A line may carry multiple aliases; wildcard or
negated patterns and aliases that are not plain printable ASCII are skipped.
Every other keyword — `HostName`, `User`, `Port`, `ProxyCommand`, and the rest
— is ignored here and left to `ssh`, which reads the same file. `Match` blocks
are ignored, including their `Include` lines. `Include` files are read one
level deep, up to 16 files: relative paths start at the `.ssh` directory, and
absolute and `~/` paths are accepted. A leading `"` groups one path containing
spaces, matching OpenSSH; a backslash is a path separator here, not an escape.

An include is skipped before the worker opens it when it is globbed, UNC
(`\\server\share`), a device path (`\\?\`, `\\.\`), or a mapped network drive
letter. The last is checked with `GetDriveTypeW`, which answers from the local
mount table without contacting the server. A directory junction or a `subst`
alias whose target is remote is not detected by that classification, but the
bounded worker below still prevents its open from stalling the UI thread.

Activating an entry runs `ssh <alias>`, so whatever that alias resolves to in
your own SSH configuration takes effect — including any `ProxyCommand` or
`LocalCommand` it specifies, which run locally. This is ordinary `ssh`
behavior; noctty adds no execution of its own, but it does turn the file into
a one-click surface.

SSH entries run without shell integration, which is injected into a local
shell and cannot apply to a remote session. Session restore does not reopen
them either: a restored window comes back with its local shells, and any SSH
pane returns as the default shell rather than dialing out unattended.

SSH entries always sort after the detected shells and cannot be reordered with
`NOCTTY_WIN32_PROFILE_ORDER`, which addresses shell profiles only.

Concrete `Include` files are scanned one level deep, up to 16 files. The root
config and Include opens run off the UI thread under one shared 50 ms refresh
budget; a slow or blocked path is skipped, and a later profile refresh can
retry it.

Set `ssh-config-hosts = false` to remove these entries. This feature does not
provide a bundled SSH client, secrets vault, or fleet/connection management.

## App identity

Installed builds create Start menu shortcuts with noctty's
AppUserModelID. Windows uses that identity for taskbar grouping and
Action Center toast activation. Portable builds run without
installer-created shortcuts, so taskbar and notification identity may be
less stable.

If Windows shows a stale icon after upgrading or switching between
installed and portable builds, restart Explorer or clear the icon cache
before assuming the build is broken.

## Default terminal

> [!WARNING]
> Default-terminal registration is experimental and not ready for normal use.
> Live validation of this revision reaches the handoff server, but the adopted
> session closes before a visible noctty window appears. Register only on a
> disposable test account or machine, and immediately unregister after testing.

Register and select noctty as the current user's default terminal with:

```powershell
noctty +register-default-terminal
```

This writes only per-user (`HKCU`) selection and COM proxy state. The installer
registers noctty's owned COM local-server and proxy classes machine-wide, but
does not change any user's default terminal. Portable builds can register the
absolute paths of the current `noctty.exe` and its sibling
`noctty-terminal-handoff-proxy.dll`; moving either file afterward requires
registering again. Registration refuses to proceed when the proxy DLL is
missing.

The three shared Microsoft `ITerminalHandoff` Interface mappings are
snapshotted before noctty changes them. Unregistration restores each prior raw
value only while that mapping still points to noctty's proxy, so a newer
terminal's registration is preserved.

noctty implements the terminal half of Windows console delegation. It requires
a Windows Terminal OpenConsole installation to remain selected as the console
half. Registration refuses to proceed when `DelegationConsole` is missing,
empty, or set to the inbox console host, rather than leaving console launches
broken. It does not verify that the selected console CLSID still resolves to an
installed application, so a value left behind by an uninstalled Windows
Terminal is accepted and console launches will degrade until a working console
half is selected again. The handoff supports `ITerminalHandoff3` only, as used
by Windows Terminal 1.24 or newer; older OpenConsole versions that request v1
or v2 are not supported and Windows falls back to a normal console window.

Because noctty is an unpackaged application, it does not appear in the Windows
Settings default-terminal picker. The registration command above selects it by
writing the per-user registry values directly, but delegated applications do
not yet survive adoption into a visible noctty window.

For a one-run handoff failure trace, set `NOCTTY_HANDOFF_TRACE=1` before
launching the delegated console application. Noctty appends the rejection
reason and HRESULT to `%LOCALAPPDATA%\noctty\handoff.log`; the opt-in file is
truncated before an append would exceed 1 MiB.

### Security properties of registration

Registering noctty as the default terminal creates a same-user activation
surface, and that is inherent to how Windows console delegation works rather
than something noctty can close. Once registered, any local process running as
the same user at the same integrity level can activate noctty's handoff class
directly and call `EstablishPtyHandoff` with pipes and a window title it
controls. The result is a genuine noctty window rendering that process's
content, with the user's keystrokes flowing back to it — a phishing shape, for
example a window titled `Administrator: Windows PowerShell`. No privilege
boundary is crossed: a process that can do this already runs as the user and
could impersonate a terminal in other ways.

The integrity check below bounds the exposure and should be preserved:

- The handoff rejects callers whose integrity level does not match noctty's
  own. That rejection is correct by design, not a bug to be relaxed later: it
  is what stops an elevated console session from being rendered inside a
  medium-integrity terminal the user's other processes can drive.

The per-user `Interface\{IID}\ProxyStubClsid32` mappings are required for
normal console-delegation clients, but they are configuration, not an access
control boundary. A same-user medium-integrity process can create an equivalent
HKCU mapping to the installer-published proxy class and activate the handoff
class directly even before the registration command has been run.

The handoff class is registered in a single-threaded apartment, and that is
load-bearing. `EstablishPtyHandoff` returns raw pty-side handles and the UI
thread closes noctty's copies later, which is safe only because the STA stub
marshals the `[out]` handles on the same thread before returning to the message
pump. Moving the class to an MTA, or running a nested modal loop while a
handoff message is dispatched, would close the handles before conhost
duplicates them and would silently break every console launch.

Undo the selection with:

```powershell
noctty +unregister-default-terminal
```

The unregister command restores the `DelegationTerminal` value saved at
registration time only when noctty is still selected, then removes noctty's
per-user COM registration. It does not overwrite a default-terminal choice
made after noctty was registered. Both commands are idempotent.

## Notifications and progress

Desktop notifications use WinRT toasts when available and fall back to
in-app banners when Windows notification policy, Focus Assist, app
identity, or runtime availability prevents a toast.

Terminal progress reports are mapped to Windows taskbar progress for the
active surface in each host window. Terminal apps can also set
in-terminal progress state through Ghostty's shared VT/OSC support.

## Power and battery

noctty reads AC/battery and saver state from `GetSystemPowerStatus`, and
subscribes to Windows power-setting notifications for the power source
(`GUID_ACDC_POWER_SOURCE`) and Battery Saver (`GUID_POWER_SAVING_STATUS`).
It additionally registers for Windows 11 Energy Saver
(`GUID_ENERGY_SAVER_STATUS`), which can engage while plugged in; Microsoft
currently documents that GUID as prerelease, so registration is best-effort
and simply does not take effect on Windows builds that lack it. Battery
Saver and Energy Saver are tracked as two independent flags and combined
with OR only when pacing is decided, so one turning off cannot cancel
pacing that the other still requires. `GetSystemPowerStatus` reports only
Battery Saver, so the fallback query carries the last notified Energy Saver
value forward instead of clearing it. A fallback query runs at most once
every 30 seconds. This has not yet been verified on
a machine with a battery -- see the status caveat below.

`unfocused-render-fps` caps presentation for visible, unfocused surfaces
and defaults to `30`. Values below `1` are treated as `1`; values above
`125` have no additional effect, since the renderer never presents more
often than every 8 ms.
`power-saver-rendering` accepts `auto`, `on`, or `off` and defaults to
`auto`: `auto` follows Windows Battery Saver or Energy Saver, `on` forces
saver pacing, and `off` disables it. `auto` deliberately does **not** key
off battery power alone: running unplugged with saver off keeps the normal
cadence, because throttling a focused terminal merely because a laptop is
unplugged is a far more aggressive default than following the saver signal
the user actually opted into. Focused surfaces retain their normal cadence
when saver pacing is inactive. Saver pacing caps presentation at about
30 fps. Minimized and DWM-cloaked host windows do not present until they
become visible again.

Cloak and uncloak have no window message, so noctty hooks the documented
`EVENT_OBJECT_CLOAKED` / `EVENT_OBJECT_UNCLOAKED` WinEvents with a single
`SetWinEventHook` scoped to this process and the UI thread. Without it, a
virtual-desktop switch that uncloaks a background window need not send
`WM_ACTIVATE`, `WM_SHOWWINDOW`, or `WM_WINDOWPOSCHANGED`, and since hidden
surfaces skip rendering entirely there would be no self-healing path back
to visible. The window messages above remain as a fallback for a missed
event or a failed hook registration, which degrades to the previous
behaviour rather than failing window creation. The callback forwards which
of the two events fired: the refresh it triggers re-queries
`DwmGetWindowAttribute(DWMWA_CLOAKED)`, and if that query fails the
observed transition is used instead of the last known cloak state, because
preserving a stale "cloaked" across an uncloak would leave the window
hidden with nothing left to re-query it. This hook path is argued from the
Win32 contract and covered by unit tests over the pure event filter and the
pure cloak-resolution policy; it has not been observed on hardware -- see
the status caveat below.

Focus here is **per surface, not per window**. In a split, only the pane
with keyboard focus presents at the full rate; the other panes are
"unfocused" even though you can see them, so a split tailing fast output
side by side with your active pane is capped at `unfocused-render-fps`
(30 by default). Raise that value if you watch live output in a background
split.

Set `NOCTTY_RENDER_TRACE_FILE` to an absolute output path to write a JSON
render trace when the first traced surface is destroyed. Presented fps
can be derived as
`(swap_buffers_count - 1) * 1000 / (last_swap_at_ms - first_swap_at_ms)`
when at least two swaps are present and the time difference is positive.

## Keyboard

Key events are translated with the active Windows keyboard layout, so the
terminal receives the text a key produces on that layout rather than a
US-layout approximation. Control chords are encoded from the *unmodified*
layout text: `ctrl+c` sends `0x03`, and combinations that have no C0 byte
(`ctrl+,`, `ctrl+.`, `ctrl+m`, `ctrl+i`, `ctrl+[`) send the fixterms
`CSI <codepoint>;5u` form that editors such as Neovim and Helix understand.

AltGr is treated as a layout shift, not as a Ctrl+Alt chord. Windows
synthesizes left Ctrl plus right Alt whenever AltGr is pressed, and noctty
drops that synthetic pair so `AltGr+<key>` produces the layout character (or
nothing) instead of a Ctrl+Alt terminal sequence.

That collapse only applies on layouts that actually define AltGr mappings,
which are the only layouts where Windows injects the synthetic Ctrl. On a
layout without an AltGr — plain US, for example — left Ctrl plus right Alt can
only be a chord you pressed, and it is passed through as one. On a layout that
does have an AltGr, the two are not distinguishable from the modifier state
noctty reads, so left Ctrl plus right Alt is always read as AltGr there; use
the left Alt key or the right Ctrl key for a deliberate Ctrl+Alt chord.

Console applications reached through ConPTY see these sequences through
conhost's own decoder, which does not translate every form back into a console
key record. `[Console]::ReadKey()` therefore reports less than the terminal
actually sent; applications that read the byte stream directly see everything.

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
named layouts, and native settings behind one fuzzy-ranked, keyboard-driven
list. Type a prefix to filter one category: `>` actions, `@` tabs, `/` panes,
`~` profiles, `:` settings, `%` themes, `!` recent commands, `^` layouts, or
`?` for help. The native Settings
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

## Named layouts

A named layout captures the focused window's tabs, split trees, selected
profiles, working directories, and explicit pane and tab titles. Saving omits
window position, size, and state. Each layout is the existing session-state
JSON schema with exactly one window, stored as
`%LOCALAPPDATA%\noctty\layouts\<name>.json`. Per-pane commands come from the
saved profiles; layout files do not contain a separate command field.

Layout names accept ASCII letters, digits, spaces, dots, underscores, and
hyphens, up to 64 bytes. Leading or trailing spaces and dots are rejected, as
are Windows reserved device names such as `CON` or `COM1`. A corrupt or
structurally invalid layout file is quarantined with the same `.corrupt` rules
as session state; a transient read failure is reported without quarantining the
file, so a locked or briefly unavailable layout is not moved aside. A layout is
refused, without quarantine, if it would open more than 16 tabs or 64 panes.
Window position, size, and maximized state are stripped before layout
validation and ignored on launch, because a layout describes a shape and not
a placement. This includes partial or stale geometry such as `x` without `y`
or a zero width; those fields do not quarantine an otherwise valid shape.

Treat the `layouts\` directory as config-level trust: launching a layout starts
one shell per pane, using the working directories and profiles that the layout
file names. If you sync or share that directory, anyone who can write to it can
influence what your next layout launch runs, exactly as they could by editing
your config.

Bind `save_layout:<name>` to save or atomically replace a layout, and bind
`launch_layout:<name>` to materialize it in a new window. Saved layouts also
appear in the command palette as `Launch layout: <name>`. From the command
line, `noctty +new-window --launch-layout=<name>` forwards the request to a
running instance or launches it cold when no instance is running.

The warm (running-instance) half of that command does **not** travel as a
forwarded configuration argument. It uses a dedicated IPC request kind whose
whole payload is the layout name, revalidated on the receiving side against the
same character, length, traversal and reserved-device rules the CLI applies, and
resolved server-side against `%LOCALAPPDATA%\noctty\layouts\`. Because of that,
`--launch-layout` cannot be combined with other `+new-window` arguments; mixing
them is refused rather than partly honoured.

`launch-layout` is deliberately **not** on the forwarded-argv allowlist and will
not be added: a layout names a file that selects profiles, and profiles carry
commands, which is the code-selecting class that allowlist exists to refuse. The
keybind and the command palette do not go over IPC at all.

`--launch-layout` is a command-line-only, one-shot option: setting
`launch-layout` in `config.ghostty` is ignored with a warning, because a
configuration file is read on every start and the layout would otherwise
replay on each launch instead of when you ask for it. The layout module also
exposes name enumeration and the `+new-window --launch-layout=<name>` argv
builder for future Windows jump-list integration; noctty does not currently add
jump-list layout entries.

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

## Quick select

`Ctrl+Shift+Space` runs `toggle_quick_select` for the focused terminal
surface. Quick select scans the visible viewport once when it opens and
labels matching URLs, paths, git SHAs, IP addresses, and UUIDs. Type a label
to select its target. Backspace removes one typed label character, and Esc
cancels and returns keyboard focus to the terminal.

Completing a label copies its matched text to the clipboard. Hold Ctrl while
completing the label to open a target that begins with an allowed URL scheme;
other targets are copied. Hold Alt to paste through the normal protected-paste
path.

Opening is deliberately narrower than matching. `file:` URLs are labeled and
can be copied, but Ctrl will not open them, because the system handler would
run `file:///C:/...exe` straight from terminal output. Anything without an
allowed scheme is copied instead of opened. Alt-paste additionally runs the
same classifier the drag-and-drop path uses, so a match carrying shell
metacharacters, environment-variable expansion, or control bytes raises the
paste confirmation.

Targets are re-checked against the live screen at the moment you act. If the
program running in the terminal rewrote a labeled region while the overlay was
up, that target is ignored rather than acted on, so what you act on is always
what was on screen. Quick select also closes on resize, on a click, and when
the surface loses focus.

`quick-select-patterns` is repeatable and accepts bare regex values or quoted
Zig string literals. An empty value clears configured patterns; when the
configured list is empty, the built-in patterns apply. `quick-select-alphabet`
sets the unique printable ASCII characters used for labels, requires at least
two characters, and treats ASCII letters that differ only by case as duplicates.

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

The named pipe behind it is restricted to processes running as the same
user: it is created with `PIPE_REJECT_REMOTE_CLIENTS` and a protected
DACL whose single ACE grants access to the SID of the token that owns
the running noctty process. Every pipe is also labeled explicitly with
the process token's exact integrity level and a `NO_WRITE_UP`
mandatory-label ACE. Above medium integrity, that label prevents a
filtered (non-elevated) token of the same account from driving the
elevated instance; at medium integrity, the explicit label lets clients
reject an otherwise unlabeled same-user pipe squatter.

That denial is **observed against a real elevated instance**, not
inferred. From a medium-integrity process, `CreateFileW` on the elevated
instance's pipe fails with `win32=5` for both
`GENERIC_READ | GENERIC_WRITE` and `GENERIC_WRITE` alone — the refusal
happens at `CreateFileW`, not as a timeout or a missing acknowledgement.
At the command line `+perform-action` and `+list-windows` exit 2 with
"No matching noctty instance is listening", and `+new-window` exits 0
having quietly started its **own** local instance rather than driving the
elevated one. From an elevated shell `+perform-action new_tab` still
succeeds, so `NO_WRITE_UP` does not lock out the intended client. The
live descriptor reads back
`D:P(A;;FA;;;S-1-5-21-...-1001)S:AI(ML;;NW;;;HI)`, confirming the label
survives object creation; a medium-integrity instance reads back the same
DACL with `S:AI(ML;;NW;;;ME)`, proving that the endpoint is labeled
explicitly at every integrity level.

**Known residual — a lower-integrity process can stall the channel.** The
label sets `NO_WRITE_UP` only, so it does not deny *reads*: a medium
process can open the elevated instance's pipe for `GENERIC_READ` (a bare
`READ_CONTROL` is enough — it need not ask for read data access at all).
`WriteFile` on that handle then fails with `win32=5`, so this is an
**occupancy problem, not an access break**: the squatter learns nothing
and can submit nothing. But because the server offers one pipe instance
at a time, a single such open makes the next legitimate client fail with
`win32=231 ERROR_PIPE_BUSY` while the server logs
`failed to process win32 IPC client err=error.IpcTimeout`. The cost is
availability of the automation channel, bounded by the server's read
timeout and repeatable.

**This residual is closed by the elevation work, not here.** That change
labels the elevated endpoint `NWNR` instead of `NW`, and the added
`NO_READ_UP` denies *every* medium-integrity open — including
`GENERIC_READ` and `READ_CONTROL` — which has been verified on hardware
against a live elevated instance. It is deliberately not duplicated in
this change: the two would collide on the same SDDL term for no net gain
once both land, and altering the label here would invalidate the
descriptor readback recorded above. Keeping a spare listening instance
was also considered and rejected as a speed bump — an attacker simply
opens one more.

**This is not a privilege boundary.** Any code already running as your
user is fully trusted with this channel: it can list your windows,
perform allowlisted actions, and open new windows. Treat the automation
surface the way you would treat your own shell — it reduces exposure to
other accounts and to the network, not to malware running as you.

The pipe *name* is derived from `--class` alone, so it is predictable and
lives in the machine-wide named-pipe namespace: any local account can
create it before noctty does. noctty therefore authenticates the **server**
as well as the client. Before writing anything to a pipe it did not create,
a client reads the owner SID and mandatory-integrity label from the security
descriptor attached to that connected pipe object. The owner must match the
client's user SID and the pipe's integrity must be at least the client's; a
mismatch is treated as "no instance we can reach", and the launch starts its
own local instance instead. Authentication is object-bound rather than based
on a numeric server PID that could be recycled after a duplicated pipe handle
outlives its creating process.

Clients also open the pipe with `SECURITY_SQOS_PRESENT |
SECURITY_IDENTIFICATION`. A named-pipe server impersonates at
`SecurityImpersonation` by default, so without that flag a squatting server
could act *as* the connecting user; with it, the server can determine who
connected but cannot use the token to open anything.

Together these stop another *account* from harvesting forwarded arguments,
forging an acknowledgement, or borrowing the connecting user's token. They
do not — and cannot — stop another process running as **you**, which is the
same trust boundary as everything else in this section.

List windows, tabs, and panes:

```powershell
noctty +list-windows
```

The JSON schema is `noctty.windows.v3`. It exposes instance, window, tab,
and pane metadata, including nullable pane titles and working directories. It
never includes terminal grid text, scrollback, selection, clipboard contents,
pending shell input, or pane process IDs.

The CLI can invoke a keybinding action, create tabs or splits, focus a target,
and deliver policy-checked printable text. For example:

```powershell
noctty +perform-action new_tab
noctty +perform-action --surface-id=<surface_id> toggle_fullscreen
noctty +new-tab --window-id=<window_id>
noctty +new-split --surface-id=<surface_id> --direction=right
noctty +focus --surface-id=<surface_id>
noctty +send-text --surface-id=<surface_id> -- "hello"
```

Actions use the same names as `keybind` values. `--surface-id` is only
valid for surface-scoped actions; app-scoped actions such as `quit`
always target the app. The running instance rejects terminal-input and
arbitrary file helper actions (`text`, `csi`, `esc`,
`paste_from_clipboard`, `write_screen_file`, `end_key_sequence`,
`clear_screen`, and `crash`), and new keybinding action variants stay
disabled for automation until they are reviewed and allowlisted.

`undo` and `redo` are refused for the same reason. They do not name a
dangerous action themselves — they *replay* one that was captured earlier,
and the Win32 undo stack can hold a `clear_screen` entry whose replay
queues the same write `clear_screen` was delisted for. An action that can
re-run another action inherits everything that action can do.

`+new-window` forwards command-line arguments to the running instance.
The running instance applies an **allowlist**: only window-scoped
presentation settings are honored, and every other key is refused. The
allowlist covers window geometry and decoration (`--window-width`,
`--window-height`, `--window-position-*`, `--window-padding-*`,
`--window-decoration`, `--maximize`, `--fullscreen`, ...), `--title`,
non-name font settings (`--font-size`, `--font-thicken`, ...), and
colors (`--background`, `--foreground`, `--palette`, `--cursor-color`,
`--background-opacity`, ...).

Everything else is refused, including anything that would run code
(`--command`, `--initial-command`, `-e`, `--input`, `--env`), load a
file (`--background-image`, `--custom-shader`, `--bell-audio-path`),
change the configuration source (`--config-file`,
`--config-default-files`, `--theme`), or write to the terminal
(`--keybind`, `--command-palette-entry`, `--enquiry-response`). A key
that is not on the allowlist — including one added by a future
release — is refused by default rather than allowed by omission. The
whole request is refused rather than the key being dropped.

`--working-directory` is allowed as `home`, `inherit`, `~/...`, or a
drive-letter absolute path. UNC *syntax* (`\\host\share`) is
refused so the running instance is not made to authenticate to a remote
SMB host. Note this is a check on syntax only: a mapped or `subst`
drive, or a junction under a local drive, still resolves off-box.

When you launch noctty normally and an instance is already running, any
argument the running instance would refuse is dropped by the launching
process before forwarding, with a warning in the log, so you still get a
window. That drop is a convenience on your own command line, not a
security control — the running instance re-checks every argument.

`launch_layout:<name>` and `save_layout:<name>` are allowlisted. Launching a
layout selects the same named-layout action as the dedicated warm-instance IPC
request. Saving is the one automation action that writes a file: it is
limited to a validated layout name under `%LOCALAPPDATA%\noctty\layouts\`,
writes atomically, and **replaces an existing layout of the same name without
prompting**. It only accepts the focused target, so `--surface-id` is rejected.

noctty exposes a local, current-user CLI surface for versioned JSON state
and policy-bounded window, tab, split, focus, action, and text operations.
The stable verb, schema, exit-code, trust, and privacy contract is in
[automation.md](automation.md).

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

`noctty.com` is the console launcher and remains the recommended way to run
CLI actions. Invoking `noctty.exe +<action>` directly also works: the
Windows-subsystem binary attaches to the console it was launched from before
running the action, and leaves redirected output alone.
