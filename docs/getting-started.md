# Getting started

noctty runs on Windows 10 version 1809 (build 17763) or newer and Windows 11,
x64 and ARM64. The default renderer needs a GPU driver with OpenGL 4.3 or
newer; where there is none, noctty draws text with its Direct3D 11 renderer
(beta) instead (see [the Windows guide](windows.md#starting-without-opengl)).

## Install with WinGet, Scoop or Chocolatey

```powershell
winget install --id AmanThanvi.noctty -e
```

WinGet runs the release installer, which does not add `noctty` to PATH. Scoop
uses the same release assets and checksums and does put `noctty` on PATH:

```powershell
scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty
scoop install noctty/noctty
```

The Chocolatey package runs the same installer as WinGet. chocolatey.org
reviews each version before listing it, so a new release can reach it after the
other channels:

```powershell
choco install noctty
```

Then skip to [First launch](#first-launch).

## Install by hand

The current stable release is `1.3.135`. Every release ships these files for
`<arch>` = `x64` and `arm64`:

| File                                                    | What it is                        |
| ------------------------------------------------------- | --------------------------------- |
| `noctty-<version>-windows-<arch>-setup.exe`             | Installer                         |
| `noctty-<version>-windows-<arch>-portable.zip`          | Portable build                    |
| `noctty-<version>-windows-<arch>-portable.manifest.ps1` | Signed hashes of the ZIP contents |
| `SHA256SUMS-windows-<arch>.txt`                         | Checksums for the files above     |

Hash the file you downloaded before you run it, whichever one that is:

```powershell
Get-FileHash .\noctty-<version>-windows-<arch>-setup.exe -Algorithm SHA256
Get-FileHash .\noctty-<version>-windows-<arch>-portable.zip -Algorithm SHA256
```

Compare the result with the matching line in `SHA256SUMS-windows-<arch>.txt`.
On a mismatch, delete the file and download it again. Provenance and signature
checks are in [verify-release.md](verify-release.md).

### Installer

1. Run `noctty-<version>-windows-<arch>-setup.exe`.
2. If SmartScreen says "Windows protected your PC", click **More info**, then
   **Run anyway**.
3. Accept the MIT license and install.
4. Launch noctty from the Start menu.

### Portable

Extract the ZIP anywhere and run `noctty.exe`. SmartScreen may warn here too.
Keep the folder together: `noctty.exe` needs the `share` folder next to it for
themes, terminfo, and shell integration. `.\noctty.com +register-shell-menu`
adds an "Open noctty here" entry to Explorer's right-click menu.

To keep config, state, and cache in that folder too, create an empty
`noctty.portable` file beside `noctty.exe`; extraction alone does not enable
portable mode. `portable.txt` and an existing `config.ghostty` regular file
are also recognized markers; directories are not. A lone `config.ghostty`
is ignored when the executable's directory is the `InstallLocation` the
installer registered.

Neither install adds `noctty` to PATH. The `noctty +...` commands below assume
you added the install folder to PATH or are running from it.

### About the SmartScreen warning

The installer, the manifest, and the binaries inside the portable ZIP are
Authenticode-signed with a self-signed certificate. That certificate has no
publisher reputation, so SmartScreen warns on first run, and the warning does
not fade with time. What each check proves, and the publisher key the updater
pins, are in [verify-release.md](verify-release.md).

## First launch

noctty creates `%LOCALAPPDATA%\noctty\` and writes a config template to
`%LOCALAPPDATA%\noctty\config.ghostty`. In portable mode it uses
`config.ghostty` beside `noctty.exe` instead, and the `%LOCALAPPDATA%` copy is
ignored. The first tab runs PowerShell 7 if it is installed, else Windows
PowerShell, else Command Prompt; see [Shell](#shell) to change it.

## Font and theme

Open the config with `notepad "$env:LOCALAPPDATA\noctty\config.ghostty"` (or
the `config.ghostty` beside `noctty.exe` in portable mode) and add a few
options:

```ini
font-family = JetBrains Mono
font-size   = 12
# Pick a theme from: noctty +list-themes
# Theme files are config files; only use themes from sources you trust.
theme       = Dracula
```

`noctty +list-fonts` shows a family whose typographic name differs from the
name Windows registers as `Legacy (Typographic)`, for example
`JetBrainsMono NFM (JetBrainsMono Nerd Font Mono)`; `font-family` accepts
either name.

Save, then press `Ctrl+Shift+,` to reload without restarting.
`noctty +show-config --default --docs | more` lists every option with its
docs, including the keybind grammar.

When the config has a mistake (an unknown key, a value that does not parse, an
include that is missing, a theme or font that is not installed), noctty shows
an error banner with the number of problems and the first one, and the banner
stays until you close it in each window. Windows opened later receive the same
load's problems, including when `initial-window = false`. If another error is
already showing, close that error to see the config problems next. Missing
families are checked across the regular, bold, italic and bold-italic lists,
including fallback entries, and listed once per config load, however many tabs
you open. **Config problems** in the command palette opens
Settings > Advanced, which lists the problems with their file and line where
noctty knows them, and shows the file Settings saves to. When the list does not
fit, or a line is cut short, `noctty +validate-config` prints the problems in
the config files in full in a terminal.

## Keybindings

Defaults are Ctrl chords, mostly the same as Ghostty's non-macOS defaults.
Pane focus on `Alt+Arrow` is Windows-specific.

| Action                      | Binding                             |
| --------------------------- | ----------------------------------- |
| Copy                        | `Ctrl+Shift+C` or `Ctrl+Insert`     |
| Paste                       | `Ctrl+Shift+V` or `Shift+Insert`    |
| New tab                     | `Ctrl+Shift+T`                      |
| Close tab                   | `Ctrl+Shift+W`                      |
| Undo / redo                 | `Ctrl+Shift+Z` / `Ctrl+Shift+Y`     |
| Next / previous tab         | `Ctrl+Tab` / `Ctrl+Shift+Tab`       |
| Go to tab 1-8               | `Alt+1` through `Alt+8`              |
| Go to last tab              | `Alt+9`                             |
| Split pane right            | `Ctrl+Shift+\`                      |
| Split pane down             | `Ctrl+Shift+E`                      |
| Move between panes          | `Alt+Arrow`                         |
| Move focus to the tab strip | `Ctrl+F6` / `Ctrl+Shift+F6`         |
| Command palette             | `Ctrl+Shift+P`                      |
| Quick select                | `Ctrl+Shift+Space`                  |
| Copy mode                   | `Ctrl+Shift+X`                      |
| Start search                | `Ctrl+Shift+F`                      |
| Next / previous match       | `F3` / `Shift+F3`                   |
| Full screen                 | `F11`                               |
| Increase / decrease font    | `Ctrl+=` / `Ctrl+-`                 |
| Reload config               | `Ctrl+Shift+,`                      |

`F6`, `Ctrl+Enter` and `Alt+Enter` are not bound, so they go to the program in
the pane (`F6` is htop's and Midnight Commander's). `F3`, `Shift+F3` and the
undo chords act only when there is a search to step through or something to
undo (a closed tab or split, `clear_screen`, `reset`); otherwise they reach
the program too. `Ctrl+F6` moves keyboard focus between the terminal, the tab
strip, the docked search and the host banner; `Esc` returns to the terminal.

`Ctrl+Shift+Y` now redoes an action; **Copy Last Command Output** remains in
the command palette and can be given a custom `copy_last_command_output`
keybind. Fullscreen moved from `Ctrl+Enter` to `F11`, and the focus cycle
moved from `F6` / `Shift+F6` to `Ctrl+F6` / `Ctrl+Shift+F6`.

`noctty +list-keybinds` prints the full list. `Ctrl+Shift+O` also splits
right; the docs use `Ctrl+Shift+\` because Narrator can reserve O-based
commands. Rebind with `keybind = <trigger>=<action>`:

```ini
keybind = ctrl+t=new_tab
keybind = ctrl+shift+r=reload_config
```

## Shell

noctty detects PowerShell, cmd, Git Bash, and WSL distributions and lists them
in the profile picker. Without a `command`, a new tab runs `pwsh.exe` (PowerShell
7) when it is on `PATH`, otherwise Windows PowerShell, otherwise Command Prompt.
`noctty --safe-mode` always starts `cmd.exe /D`, which loads no PowerShell
profile and skips cmd's `AutoRun` command. To pin a shell as the default:

```ini
command = pwsh.exe
```

Any name on PATH works. A plain value goes through `cmd.exe /C`, which stops
reading at the first space, so a full path with spaces needs the `direct:`
form and quotes:

```ini
command = direct:"C:\Program Files\Git\bin\bash.exe"
```

WSL shows up in the picker but is never the default unless you set
`command = wsl.exe`. More on shells in [windows.md](windows.md#shells).

## Updates

noctty checks GitHub Releases on launch, and about every six hours while a
window stays open, unless a check succeeded in the last 24 hours, and never
installs anything until you start it. `auto-update = off` disables the
check. `auto-update = download` also downloads and verifies the installer
ahead of time; you still choose when to install. Details are in
[windows.md](windows.md#updates).

## If something goes wrong

If a broken config or saved session blocks launch, start once with built-in
defaults and no session restore:

```powershell
noctty --safe-mode
```

Safe mode still needs OpenGL 4.3; without it, see
[Starting without OpenGL](windows.md#starting-without-opengl).

Crash dumps stay local under `%LOCALAPPDATA%\noctty\crash`; read them with
`noctty +crash-report`. Recovery and diagnostic bundles are in
[windows.md](windows.md#crash-reports-and-diagnostics).

## Uninstall

Installer builds: Settings, Apps, Installed apps, noctty, Uninstall. Portable
builds: run `.\noctty.com +unregister-shell-menu` if you registered the
Explorer entry, then delete the folder. Neither removes
`%LOCALAPPDATA%\noctty\`; delete it yourself for a clean slate.

## More

- [status.md](status.md): what works, what is experimental, known caveats
- [windows.md](windows.md): the Windows behavior reference
- [automation.md](automation.md): drive noctty from the CLI
- [HACKING.md](../HACKING.md) and [CONTRIBUTING.md](../CONTRIBUTING.md)
- [Discussions](https://github.com/amanthanvi/noctty/discussions): questions
