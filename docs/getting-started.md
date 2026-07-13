# Getting started

Step by step: download, install, launch, configure, and uninstall.

## 1. Download

Install with WinGet:

```powershell
winget install AmanThanvi.winghostty
```

Or install from the fork-owned Scoop bucket:

```powershell
scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty
scoop install winghostty/winghostty
```

You can also go to
[Releases](https://github.com/amanthanvi/winghostty/releases) and grab:

- **Installer:** `winghostty-<version>-windows-<arch>-setup.exe`
- **Portable ZIP:** `winghostty-<version>-windows-<arch>-portable.zip`
- **Checksums:** `SHA256SUMS-windows-<arch>.txt`

Use `x64` or `arm64` for `<arch>`. The current stable release is `1.3.118`;
both architectures have installer and portable ZIP assets. The legacy
`SHA256SUMS.txt` file remains an x64 compatibility alias.

Verify a download (optional):

```powershell
Get-FileHash .\winghostty-<version>-windows-<arch>-setup.exe -Algorithm SHA256
# Compare the output against SHA256SUMS-windows-<arch>.txt
```

## 2. Install

### Option A — Package manager

Use the WinGet or Scoop commands above. Both official package-manager tracks
point at the same GitHub Release assets and checksums.

### Option B — Installer

1. Double-click `winghostty-<version>-windows-<arch>-setup.exe`.
2. If SmartScreen says _"Windows protected your PC"_, click **More info** →
   **Run anyway**. Release builds are Authenticode-signed, but SmartScreen
   reputation can lag behind signing for a new publisher, so the warning may
   appear even though the signature is present and valid.
3. Accept the MIT license and install.
4. Launch **winghostty** from the Start menu.

### Option C — Portable

1. Extract the ZIP anywhere (for example, `C:\Tools\winghostty\`).
2. Run `winghostty.exe`.
3. The Windows binaries inside the ZIP are Authenticode-signed. The ZIP
   container itself is checksummed, not Authenticode-signed, so SmartScreen
   may show the same warning.

## 3. First launch

On first launch, winghostty creates `%LOCALAPPDATA%\winghostty\` and writes a
config template at `%LOCALAPPDATA%\winghostty\config.ghostty` with inline
syntax notes. It then picks a conservative default shell; you can override
that with `command = <path>` in your config (see below).

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

Save, then reload config without restarting: **Ctrl + Shift + ,**

See every option with inline docs:

```powershell
winghostty +show-config --default --docs | more
```

## 5. Keybindings

Default keybindings follow Windows conventions. Full list:

```powershell
winghostty +list-keybinds
```

The defaults you'll reach for daily:

| Action                   | Binding                         |
| ------------------------ | ------------------------------- |
| Copy                     | `Ctrl+Shift+C`                  |
| Paste                    | `Ctrl+Shift+V`                  |
| New tab                  | `Ctrl+Shift+T`                  |
| Close tab                | `Ctrl+Shift+W`                  |
| Next / previous tab      | `Ctrl+Tab` / `Ctrl+Shift+Tab`   |
| Split right / down       | `Ctrl+Shift+O` / `Ctrl+Shift+E` |
| Start search             | `Ctrl+Shift+F`                  |
| Increase / decrease font | `Ctrl+=` / `Ctrl+-`             |
| Reload config            | `Ctrl+Shift+,`                  |

Rebind anything:

```ini
keybind = ctrl+t>new_tab
keybind = ctrl+shift+r>reload_config
```

Keybind grammar (chords, `catch_all`, modifiers) is documented inline in
`+show-config --default --docs`.

## 6. Pick your shell

winghostty auto-detects installed Windows shells (PowerShell, `cmd`, Git
Bash, opt-in WSL) and exposes them through an in-app profile picker. To pin a
specific shell instead, set it in your config:

```ini
command = <path>
```

WSL works as a launched shell, but you have to opt in explicitly:

```ini
command = wsl.exe
```

Why WSL is never picked implicitly — and other shell behavior details — is
covered in [windows.md](windows.md#shells).

## 7. Updates

Turn on update checks in your config:

```ini
auto-update = check
```

The updater checks GitHub Releases at most once every 24 hours and never
replaces binaries silently. `auto-update = download` additionally stages
verified installers for a user-initiated apply. Verification details and
`download`-mode behavior are in [windows.md](windows.md#updates).

## 8. If something goes wrong

If configuration or saved session state prevents a normal launch, start once
with built-in defaults and no session restore:

```powershell
winghostty --safe-mode
```

Crash dumps, if any, stay local under `%LOCALAPPDATA%\winghostty\crash` —
read them with `winghostty +crash-report`. Recovery behavior, crash-report
details, and diagnostic bundles are covered in
[windows.md](windows.md#crash-reports-and-diagnostics).

## 9. Automate it

winghostty has a local automation surface: `winghostty +list-windows` reports
windows, tabs, and panes as JSON, and `winghostty +perform-action` invokes
keybinding actions over IPC. The full surface, including what it deliberately
refuses to do, is documented in [windows.md](windows.md#automation).

## 10. Uninstall

- **Installer builds:** _Settings → Apps → Installed apps → winghostty →
  Uninstall_.
- **Portable builds:** delete the folder you extracted to.

Your config and any crash logs live under `%LOCALAPPDATA%\winghostty\` and
are not removed by either path. Delete that folder manually for a clean
slate.

## Next steps

- [docs/status.md](status.md) — what works, what's experimental, known
  caveats
- [docs/windows.md](windows.md) — the Windows behavior reference: paths,
  shells, updates, automation, and troubleshooting
- [docs/windows-capability-matrix.md](windows-capability-matrix.md) —
  row-by-row mapping against upstream Ghostty docs
- [HACKING.md](../HACKING.md) — build, test, and runtime notes for
  developers
- [CONTRIBUTING.md](../CONTRIBUTING.md) — how to submit changes
- [Discussions](https://github.com/amanthanvi/winghostty/discussions) —
  questions and feedback
