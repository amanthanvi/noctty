# Getting started

Download, install, and set up winghostty on Windows. You need Windows 10
or 11 on x64 or ARM64 and a GPU driver with OpenGL 4.3 or newer.

## 1. Install with a package manager

The quickest path. With WinGet:

```powershell
winget install AmanThanvi.winghostty
```

Or with Scoop, from the project's own bucket:

```powershell
scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty
scoop install winghostty/winghostty
```

Both tracks point at the same GitHub Release assets and checksums.
Scoop also puts `winghostty` on your PATH; WinGet does not, so the PATH
note at the end of step 2 applies to WinGet installs too. Either way,
you can continue at step 3.

## 2. Or download and install manually

Go to [Releases](https://github.com/amanthanvi/winghostty/releases). The
current stable release is `1.3.123`, and `<arch>` is `x64` or `arm64`;
both architectures ship every asset:

- Installer: `winghostty-<version>-windows-<arch>-setup.exe`
- Portable ZIP: `winghostty-<version>-windows-<arch>-portable.zip`
- Checksums: `SHA256SUMS-windows-<arch>.txt`

The legacy `SHA256SUMS.txt` file remains an x64 compatibility alias.

To verify a download (optional), grab `SHA256SUMS-windows-<arch>.txt`
from the same release, then:

```powershell
Get-FileHash .\winghostty-<version>-windows-<arch>-setup.exe -Algorithm SHA256
# Compare the output against SHA256SUMS-windows-<arch>.txt
```

### Installer

1. Double-click `winghostty-<version>-windows-<arch>-setup.exe`.
2. If SmartScreen says _"Windows protected your PC"_, click **More info**,
   then **Run anyway**. See the note below on why this warning appears.
3. Accept the MIT license and install.
4. Launch **winghostty** from the Start menu.

### Portable

1. Extract the ZIP anywhere (for example, `C:\Tools\winghostty\`).
2. Run `winghostty.exe`. SmartScreen may show the same warning here.

Keep the whole extracted folder together: `winghostty.exe` needs the
`share` folder next to it for themes, terminfo, and shell integration.

Neither the installer nor the portable ZIP adds `winghostty` to your
PATH. The `winghostty +...` commands below assume you've either added
the folder containing `winghostty.exe` to PATH or are running them from
that folder.

### About the SmartScreen warning

Release installers and the Windows binaries inside the portable ZIP are
Authenticode-signed. The ZIP container itself is checksummed, not signed.
SmartScreen trust is based on publisher reputation, which builds over
time and lags behind the signature for a new publisher, so you may see
the warning even though the signature is present and valid. If you want
an extra check, verify the download against
`SHA256SUMS-windows-<arch>.txt` as shown above before running it.

## 3. First launch

On first launch, winghostty creates `%LOCALAPPDATA%\winghostty\` and
writes a config template at `%LOCALAPPDATA%\winghostty\config.ghostty`
with inline syntax notes. It then picks a conservative default shell; you
can override that in your config (see step 6).

## 4. Set a font and theme

Open the config file:

```powershell
notepad "$env:LOCALAPPDATA\winghostty\config.ghostty"
```

Add a few options:

```ini
font-family = JetBrains Mono
font-size   = 12
# Pick a theme from: winghostty +list-themes
# Theme files are config files; only use themes from sources you trust.
theme       = Dracula
```

Save, then reload config without restarting: `Ctrl+Shift+,`

See every option with inline docs:

```powershell
winghostty +show-config --default --docs | more
```

## 5. Keybindings

Defaults are Ctrl-based chords, mostly shared with Ghostty's non-macOS
defaults (pane focus on `Alt+Arrow` is a Windows-specific touch). The
ones you'll use daily:

| Action                   | Binding                         |
| ------------------------ | ------------------------------- |
| Copy                     | `Ctrl+Shift+C`                  |
| Paste                    | `Ctrl+Shift+V`                  |
| New tab                  | `Ctrl+Shift+T`                  |
| Close tab                | `Ctrl+Shift+W`                  |
| Next / previous tab      | `Ctrl+Tab` / `Ctrl+Shift+Tab`   |
| Split right / down       | `Ctrl+Shift+\` / `Ctrl+Shift+E` |
| Move between panes       | `Alt+Arrow`                     |
| Command palette          | `Ctrl+Shift+P`                  |
| Start search             | `Ctrl+Shift+F`                  |
| Increase / decrease font | `Ctrl+=` / `Ctrl+-`             |
| Reload config            | `Ctrl+Shift+,`                  |

Full list:

```powershell
winghostty +list-keybinds
```

`Ctrl+Shift+O` also splits right; `Ctrl+Shift+\` is the advertised
default because Narrator can reserve O-based commands.

Rebind anything with `keybind = <trigger>=<action>`:

```ini
keybind = ctrl+t=new_tab
keybind = ctrl+shift+r=reload_config
```

Keybind grammar (chords, `catch_all`, modifiers) is documented inline in
`winghostty +show-config --default --docs`.

## 6. Pick your shell

winghostty auto-detects installed Windows shells (PowerShell, `cmd`, Git
Bash, and WSL distributions) and exposes them through an in-app profile
picker. To pin a specific shell as your default instead, set it in your
config:

```ini
command = pwsh.exe
```

Any executable name on PATH or full path works, for example
`C:\Program Files\Git\bin\bash.exe`.

WSL appears in the profile picker, but making it the default requires
an explicit opt-in:

```ini
command = wsl.exe
```

Why WSL is never the implicit default, plus other shell behavior
details, is explained in [windows.md](windows.md#shells).

## 7. Updates

Turn on update checks in your config:

```ini
auto-update = check
```

The updater checks GitHub Releases at most once every 24 hours and never
installs anything without you starting it. `auto-update = download` also
downloads and verifies the installer ahead of time; you still choose
when to install it. Verification details and `download`-mode behavior
are in [windows.md](windows.md#updates).

## 8. If something goes wrong

If configuration or saved session state prevents a normal launch, start
once with built-in defaults and no session restore:

```powershell
winghostty --safe-mode
```

Crash dumps, if any, stay local under `%LOCALAPPDATA%\winghostty\crash`.
Read them with `winghostty +crash-report`. Recovery behavior,
crash-report details, and diagnostic bundles are covered in
[windows.md](windows.md#crash-reports-and-diagnostics).

## 9. Automate it

winghostty has a local automation surface: `winghostty +list-windows`
reports windows, tabs, and panes as JSON, and
`winghostty +perform-action` invokes keybinding actions over IPC. The
full surface, including the actions it blocks, is documented in
[windows.md](windows.md#automation).

## 10. Uninstall

- Installer builds: _Settings → Apps → Installed apps → winghostty →
  Uninstall_.
- Portable builds: delete the folder you extracted to.

Your config and any crash logs live under `%LOCALAPPDATA%\winghostty\`
and are not removed by either path. Delete that folder manually for a
clean slate.

## Next steps

- [docs/status.md](status.md): what works, what's experimental, known
  caveats
- [docs/windows.md](windows.md): the Windows behavior reference; paths,
  shells, updates, automation, and troubleshooting
- [docs/windows-capability-matrix.md](windows-capability-matrix.md):
  row-by-row mapping against upstream Ghostty docs
- [HACKING.md](../HACKING.md): build, test, and runtime notes for
  developers
- [CONTRIBUTING.md](../CONTRIBUTING.md): how to submit changes
- [Discussions](https://github.com/amanthanvi/winghostty/discussions):
  questions and feedback
