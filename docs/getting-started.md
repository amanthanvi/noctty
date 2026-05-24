# Getting started

Step by step: download, install, launch, configure, and uninstall.

## 1. Download

Go to [Releases](https://github.com/amanthanvi/winghostty/releases) and grab:

- **Installer:** `winghostty-<version>-windows-x64-setup.exe`
- **Portable ZIP:** `winghostty-<version>-windows-x64-portable.zip`
- **Checksums:** `SHA256SUMS.txt`

Verify a download (optional):

```powershell
Get-FileHash .\winghostty-<version>-windows-x64-setup.exe -Algorithm SHA256
# Compare the output against SHA256SUMS.txt
```

## 2. Install

### Option A — Installer

1. Double-click `winghostty-<version>-windows-x64-setup.exe`.
2. SmartScreen will warn *"Windows protected your PC"*. Click **More info** →
   **Run anyway**. Releases are unsigned; this warning is expected until code
   signing is added.
3. Accept the MIT license and install.
4. Launch **winghostty** from the Start menu.

### Option B — Portable

1. Extract the ZIP anywhere (for example, `C:\Tools\winghostty\`).
2. Run `winghostty.exe`.
3. SmartScreen may show the same warning.

## 3. First launch

On first launch, winghostty creates `%LOCALAPPDATA%\winghostty\` and writes a
config template at `%LOCALAPPDATA%\winghostty\config.ghostty` with inline
syntax notes. It then picks a conservative default shell. You can override
with `command = <path>` in your config (see below).

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

Save. Reload config without restarting with **Ctrl + Shift + ,**.

See every option with inline docs:

```powershell
winghostty +show-config --default --docs | more
```

## 5. Keybindings

Default keybindings follow Windows conventions. Full list:

```powershell
winghostty +list-keybinds
```

Verified defaults you'll reach for daily:

| Action | Binding |
| --- | --- |
| Copy | `Ctrl+Shift+C` |
| Paste | `Ctrl+Shift+V` |
| New tab | `Ctrl+Shift+T` |
| Close tab | `Ctrl+Shift+W` |
| Next / previous tab | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Split right / down | `Ctrl+Shift+O` / `Ctrl+Shift+E` |
| Start search | `Ctrl+Shift+F` |
| Increase / decrease font | `Ctrl+=` / `Ctrl+-` |
| Reload config | `Ctrl+Shift+,` |

Rebind anything:

```ini
keybind = ctrl+t>new_tab
keybind = ctrl+shift+r>reload_config
```

Keybind grammar (chords, `catch_all`, modifiers) is documented inline in
`+show-config --default --docs`.

## 6. Use WSL as your shell

winghostty supports WSL as a launched shell but does not pick it implicitly.
Opt in explicitly:

```ini
command = wsl.exe
```

## 7. In-app profile picker

winghostty auto-detects installed Windows shells (PowerShell, `cmd`, Git
Bash, opt-in WSL) and exposes them through an in-app profile picker.
Profile selection is an in-app runtime feature; there is no user-facing
config option to control it today. If you need to override the launched
shell, set `command = <path>` in your config.

## 8. Updates

```ini
auto-update = check
```

The updater hits GitHub's public releases API at most once every 24 hours,
opens the release page if a newer stable version is available, and never
replaces binaries silently. `auto-update = download` downloads only stable
Windows installer releases that include `SHA256SUMS.txt`, verifies the
installer SHA-256 against that manifest, requires a valid Windows Authenticode
signature, and stages the installer under the local winghostty state directory.
Installing the staged update is still manual. No telemetry or analytics are
sent.

## 9. Crash reports

winghostty keeps a local crash directory at:

```
%LOCALAPPDATA%\winghostty\crash
```

Nothing in this directory is ever uploaded. On Windows, winghostty writes local
`.dmp` minidumps for process-level unhandled exceptions when Windows can
deliver one. Inspect what is there with:

```powershell
winghostty +crash-report
```

## 10. Local automation

winghostty exposes a local Windows automation surface over the same
single-instance IPC path used by `+new-window`.

List windows, tabs, and panes:

```powershell
winghostty +list-windows
```

The JSON schema is `winghostty.windows.v2`. It exposes local window, tab, and
pane IDs, focus/active state, and structural counts only; it does not expose
terminal text, shell input, working directories, or file paths.

Invoke a keybinding action on the focused surface:

```powershell
winghostty +perform-action new_tab
```

Invoke an action on a specific pane from `+list-windows`:

```powershell
winghostty +perform-action --surface-id=<surface_id> toggle_fullscreen
```

Actions use the same names as `keybind` values. `--surface-id` is only valid
for surface-scoped actions; app-scoped actions such as `quit` always target the
app. Terminal-input and arbitrary file helper actions such as `text`, `csi`,
`esc`, `paste_from_clipboard`, `write_screen_file`, and `crash` are rejected by
the running instance. New keybinding action variants are not automation-enabled
until explicitly reviewed and added to the allowlist.

## 11. Uninstall

- **Installer builds:** *Settings → Apps → Installed apps → winghostty →
  Uninstall*.
- **Portable builds:** delete the folder you extracted to.

Your config and any crash logs live under `%LOCALAPPDATA%\winghostty\` and
are not removed by either path. Delete that folder manually for a clean
slate.

## Next steps

- [docs/status.md](status.md) — what works, what's experimental, known
  caveats
- [docs/windows.md](windows.md) — Windows-specific behavior,
  troubleshooting, paths, app identity, notifications, and shell notes
- [docs/windows-capability-matrix.md](windows-capability-matrix.md) —
  Windows-specific behavior and docs truth
- [HACKING.md](../HACKING.md) — build, test, runtime notes (for
  developers)
- [CONTRIBUTING.md](../CONTRIBUTING.md) — how to submit changes
- [Discussions](https://github.com/amanthanvi/winghostty/discussions) —
  questions and feedback
