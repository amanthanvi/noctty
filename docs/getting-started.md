# Getting started

Download, install, and set up noctty on Windows. You need Windows 10
or 11 on x64 or ARM64 and a GPU driver with OpenGL 4.3 or newer.

## 1. Install with a package manager

The `AmanThanvi.noctty` WinGet package is pending bootstrap. Until it merges,
use Scoop from the project's own bucket:

```powershell
scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty
scoop install noctty/noctty
```

Scoop points at the same GitHub Release assets and checksums and puts `noctty`
on your PATH. Continue at step 3.

## 2. Or download and install manually

Go to [Releases](https://github.com/amanthanvi/noctty/releases). The
current stable release is `1.3.124`, and `<arch>` is `x64` or `arm64`;
both architectures ship every asset:

- Installer: `noctty-<version>-windows-<arch>-setup.exe`
- Portable ZIP: `noctty-<version>-windows-<arch>-portable.zip`
- Signed portable manifest: `noctty-<version>-windows-<arch>-portable.manifest.ps1`
- Checksums: `SHA256SUMS-windows-<arch>.txt`

The legacy `SHA256SUMS.txt` file remains an x64 compatibility alias.

Verify the download before you run it. Grab
`SHA256SUMS-windows-<arch>.txt` from the same release, then hash the file
you actually downloaded. For the installer:

```powershell
Get-FileHash .\noctty-<version>-windows-<arch>-setup.exe -Algorithm SHA256
```

For the portable ZIP:

```powershell
Get-FileHash .\noctty-<version>-windows-<arch>-portable.zip -Algorithm SHA256
```

Compare the result against the matching line in
`SHA256SUMS-windows-<arch>.txt`. If it doesn't match, stop. Don't install
or extract that file; delete it and download it again.

For v1.3.124 and later, GitHub also publishes build provenance for every
release asset except the static icon. Bind the check to this repository and
the canonical release workflow:

```powershell
gh attestation verify .\noctty-<version>-windows-<arch>-portable.zip `
  --repo amanthanvi/noctty `
  --signer-workflow amanthanvi/noctty/.github/workflows/release.yml
```

The matching signed manifest covers the exact files inside the portable ZIP.
`scripts/verify-published-release.ps1` verifies the asset set, GitHub digests,
provenance, manifest signature and payload hashes, and every embedded PE
signature against the updater's pinned publisher key.

### Installer

1. Check the hash first, then double-click
   `noctty-<version>-windows-<arch>-setup.exe`.
2. If SmartScreen says _"Windows protected your PC"_, click **More info**,
   then **Run anyway**. See the note below on why this warning appears.
3. Accept the MIT license and install.
4. Launch **noctty** from the Start menu.

### Portable

1. Extract the ZIP anywhere (for example, `C:\Tools\noctty\`).
2. Run `noctty.exe`. SmartScreen may show the same warning here.

Keep the whole extracted folder together: `noctty.exe` needs the
`share` folder next to it for themes, terminfo, and shell integration.

Portable users can opt into Explorer's `Open noctty here` verb with
`.\noctty.com +register-shell-menu`.

Neither the installer nor the portable ZIP adds `noctty` to your
PATH. The `noctty +...` commands below assume you've either added
the folder containing `noctty.exe` to PATH or are running them from
that folder.

### About the SmartScreen warning

Release installers, portable payload manifests, and the Windows binaries
inside the portable ZIP are Authenticode-signed, but the current signing
certificate is self-signed. The ZIP container is checksummed and provenance
attested rather than Authenticode-signed.

A self-signed certificate carries no third-party publisher identity, so
it earns no SmartScreen reputation. The warning won't fade with time;
expect it until releases move to a CA-issued certificate.

Be precise about what the checksum buys you before you click through. It
confirms the file arrived intact and matches what the release publishes,
which is worth checking every time. It is not proof of authorship: the
checksum file sits next to the installer, so whatever could replace one
could replace the other. The value that doesn't come from the release
page is the publisher key pinned in the updater and recorded in
[ADR 0005](adr/0005-pin-updater-publisher-public-keys.md). In-app
updates are checked against that pin and refuse an installer signed by
anything else, and `scripts/verify-published-release.ps1` checks a
published release the same way.

## 3. First launch

On first launch, noctty creates `%LOCALAPPDATA%\noctty\` and
writes a config template at `%LOCALAPPDATA%\noctty\config.ghostty`
with inline syntax notes. It then picks a conservative default shell; you
can override that in your config (see step 6).

## 4. Set a font and theme

Open the config file:

```powershell
notepad "$env:LOCALAPPDATA\noctty\config.ghostty"
```

Add a few options:

```ini
font-family = JetBrains Mono
font-size   = 12
# Pick a theme from: noctty +list-themes
# Theme files are config files; only use themes from sources you trust.
theme       = Dracula
```

Save, then reload config without restarting: `Ctrl+Shift+,`

See every option with inline docs:

```powershell
noctty +show-config --default --docs | more
```

## 5. Keybindings

Defaults are Ctrl-based chords, mostly shared with Ghostty's non-macOS
defaults (pane focus on `Alt+Arrow` is a Windows-specific touch). The
ones you'll use daily:

| Action                   | Binding                       |
| ------------------------ | ----------------------------- |
| Copy                     | `Ctrl+Shift+C`                |
| Paste                    | `Ctrl+Shift+V`                |
| New tab                  | `Ctrl+Shift+T`                |
| Close tab                | `Ctrl+Shift+W`                |
| Next / previous tab      | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Split pane right         | `Ctrl+Shift+\`                |
| Split pane down          | `Ctrl+Shift+E`                |
| Move between panes       | `Alt+Arrow`                   |
| Command palette          | `Ctrl+Shift+P`                |
| Quick select             | `Ctrl+Shift+Space`            |
| Copy mode                | `Ctrl+Shift+X`                |
| Start search             | `Ctrl+Shift+F`                |
| Increase / decrease font | `Ctrl+=` / `Ctrl+-`           |
| Reload config            | `Ctrl+Shift+,`                |

Full list:

```powershell
noctty +list-keybinds
```

`Ctrl+Shift+O` also splits right; `Ctrl+Shift+\` is the advertised
default because Narrator can reserve O-based commands.

Rebind anything with `keybind = <trigger>=<action>`:

```ini
keybind = ctrl+t=new_tab
keybind = ctrl+shift+r=reload_config
```

Keybind grammar (chords, `catch_all`, modifiers) is documented inline in
`noctty +show-config --default --docs`.

## 6. Pick your shell

noctty auto-detects installed Windows shells (PowerShell, `cmd`, Git
Bash, and WSL distributions) and exposes them through an in-app profile
picker. To pin a specific shell as your default instead, set it in your
config:

```ini
command = pwsh.exe
```

Any executable name on PATH works the same way. A full path does too,
but if it contains spaces, use the `direct:` form and quote it. A plain
value is handed to `cmd.exe /C`, which would stop reading at the first
space and look for `C:\Program`:

```ini
command = direct:"C:\Program Files\Git\bin\bash.exe"
```

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
noctty --safe-mode
```

Crash dumps, if any, stay local under `%LOCALAPPDATA%\noctty\crash`.
Read them with `noctty +crash-report`. Recovery behavior,
crash-report details, and diagnostic bundles are covered in
[windows.md](windows.md#crash-reports-and-diagnostics).

## 9. Automate it

noctty has a local automation surface: `noctty +list-windows`
reports versioned JSON state, and targeted verbs can create, split,
focus, act on, and send control-free text to panes. The stable contract
is documented in [automation.md](automation.md).

## 10. Uninstall

- Installer builds: _Settings → Apps → Installed apps → noctty →
  Uninstall_.
- Portable builds: if you enabled `Open noctty here`, run
  `.\noctty.com +unregister-shell-menu` first, then delete the folder you
  extracted to.

Your config and any crash logs live under `%LOCALAPPDATA%\noctty\`
and are not removed by either path. Delete that folder manually for a
clean slate.

## Next steps

- [docs/status.md](status.md): what works, what's experimental, known
  caveats
- [docs/windows.md](windows.md): the Windows behavior reference; paths,
  shells, updates, automation, and troubleshooting
- [docs/automation.md](automation.md): CLI verbs, JSON schema, exit codes,
  and local-channel policy
- [docs/windows-capability-matrix.md](windows-capability-matrix.md):
  row-by-row mapping against upstream Ghostty docs
- [HACKING.md](../HACKING.md): build, test, and runtime notes for
  developers
- [CONTRIBUTING.md](../CONTRIBUTING.md): how to submit changes
- [Discussions](https://github.com/amanthanvi/noctty/discussions):
  questions and feedback
